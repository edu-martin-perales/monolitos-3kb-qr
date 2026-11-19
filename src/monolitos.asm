; MONOLITOS — mundo abierto procedural en primera persona, para un QR.
; .COM de DOS, VGA 13h, 386 + FPU. NASM:  build.py src/monolitos.asm
;
; Mundo: mapa de alturas toroidal de 256x256 (diamante-cuadrado + suavizado)
; con lagos y 4 plataformas antiguas. Render por columnas con altura y color
; bilineales cerca y niebla por tabla. Objetos: esferas sombreadas con z-buffer.
; Juego: reúne 3 runas, llévalas a una plataforma y alza su monolito.
; El sol se pone: si llega la noche, la tierra se pierde y nace otra.
; Cada monolito sube el sol. Las sombras guardianas te roban runas;
; dispárales luz (espacio). Alza los 4 y la tierra despierta.
;
; Segmentos: CS=SS código, constantes, variables (vía BP) y teclas
;            DS profundidad; en su cola (>=64000): 1/z, entidades, plataformas
;            FS alturas · GS colores · ES pantalla oculta
; Tiempo: la lógica corre a 72,8 Hz (PIT reprogramado + int 1Ch), igual en
;         cualquier máquina; el render va tan rápido como pueda.

bits 16
org 100h

HOR     equ 90          ; fila del horizonte
FOG     equ 118         ; índice de color de la niebla / horizonte
KV      equ 48          ; escala vertical de proyección
WATER   equ 46          ; nivel del agua
EYE     equ 8           ; altura de los ojos
NEARZ   equ 40          ; distancia con altura y color bilineales
NRUNE   equ 28
GFIRST  equ 32          ; primer guardián (múltiplo de 32: plataforma y puesto salen de los bits de SI)
NGUARD  equ 12
GEND    equ GFIRST+NGUARD
EBOLT   equ GEND        ; orbe de luz
ESUN    equ GEND+1
HFIRST  equ GEND+2      ; eclipses
NHUNT   equ 3
NENT    equ HFIRST+NHUNT
SUN0    equ 60          ; altura inicial del sol (cuenta atrás de la noche)
SUNUP   equ 24          ; lo que sube el sol con cada monolito
SUNMAX  equ 90
FOGT    equ 4000h       ; tabla de niebla en CS: [z/4][color]
SUNX    equ 30720       ; dirección del sol (relativa a la cámara)
SUNY    equ 4096
INV     equ 64000       ; en DS: 256 dwords
ENTS    equ INV+1024    ; en DS: NENT registros de 8 bytes (x, y, tipo, aux); alineado a 128
; tipos: 1 brasa de sol, 2 runa, 3 sombra guardiana, 4 eclipse, 5 luz, 6 sol
; (abatir es tipo>>2: la sombra se deshace y el eclipse deja una brasa)
SITES   equ 10000h-32   ; en DS: 4 registros (x, y, estado, cuenta, base); al final: "add ...,8 / jnz"

%define V(x) bp+(x)-BPB
%define K(s) bp+keys+(s)-BPB

start:
    fninit
    mov bp,BPB
    mov [V(v9)+2],cs
    mov [V(v1c)+2],cs
    mov al,0B6h                 ; canal 2 del PIT (altavoz): onda cuadrada
    out 43h,al
    call swap                   ; engancha teclado y reloj; DS=ES=CS
    mov ax,13h
    int 10h
    mov ax,cs
    add ah,10h
    mov fs,ax
    add ah,10h
    mov gs,ax
    add ah,10h
    push ax                     ; pantalla oculta (la recoge el final de restart)
    add ah,10h
    mov ds,ax
    mov es,ax

; ---- tabla 1/z: inv[z] = KV*256/z
    xor eax,eax
    mov di,INV+4
    xor cx,cx
    inc cx
.inv:
    mov ax,KV*256
    cwd
    div cx
    stosd
    inc cl
    jnz .inv

; ---- tabla de niebla: c + (FOG-c)*z4/64 para c<128
    xor bx,bx
.fg:
    mov al,bl
    test al,al
    js .fs
    mov al,FOG
    sub al,bl
    imul bh
    sar ax,6
    add al,bl
.fs:
    mov [cs:bx+FOGT],al
    inc bx
    cmp bh,64
    jb .fg

; ---- nace una tierra. En la pila, la pantalla oculta; DS = profundidad
restart:
    push cs                     ; variables y teclas a cero
    pop es
    mov di,bss0
    mov cx,bss1-bss0
    xor ax,ax
    rep stosb
    push ds                     ; entidades y plataformas a cero
    pop es
    mov di,ENTS
    mov ch,2
    rep stosb
    mov ah,2Ch                  ; semilla: la hora (cada partida, otra tierra)
    int 21h
    mov [V(seed)],dx
    mov [V(seed)+2],cx

; ---- alturas: diamante-cuadrado simplificado sobre toro
    mov byte [fs:0],170
    mov cl,128
.lv:
    xor bx,bx
.c:
    mov al,bl
    or al,bh
    mov ah,cl
    dec ah
    test al,ah
    jnz .n
    mov dx,bx
    and dl,cl
    and dh,cl
    test dx,dx
    jz .n
    mov ax,bx
    sub ax,dx
    add dl,dl
    add dh,dh
    xor si,si
    call nadd
    add al,dl
    call nadd
    add ah,dh
    call nadd
    sub al,dl
    call nadd
    shr si,2
    call rand                   ; desplazamiento aleatorio proporcional al paso
    mov al,cl
    imul ah
    sar ax,7
    add ax,si
    call clamp
    mov [fs:bx],al
.n:
    inc bx
    jnz .c
    shr cl,1
    jnz .lv
    mov dl,3
    call blur

; ---- forma: centrar en la media y elevar al cuadrado (llanos bajos, picos)
    xor edx,edx
.m:
    movzx eax,byte [fs:bx]
    add edx,eax
    inc bx
    jnz .m
    shr edx,16
.sh:
    movzx ax,byte [fs:bx]
    sub ax,dx
    add ax,128
    call clamp
    mul al
    mov [fs:bx],ah
    inc bx
    jnz .sh

; ---- colores: luz rasante del sol + altura; lagos-espejo; luego suavizados
.cm:
    movzx dx,byte [fs:bx]
    cmp dl,WATER
    jae .land
    shr dl,1
    add dl,64
    mov byte [fs:bx],WATER
    jmp short .st
.land:
    mov al,[fs:bx-1]
    sub al,[fs:bx+1]
    cbw
    imul ax,ax,6
    shr dx,1
    add ax,dx
    add ax,10
    add ax,ax
    call clamp
    shr al,1
    mov dl,al
.st:
    mov [gs:bx],dl
    inc bx
    jnz .cm
    push fs                     ; suavizar colores con la misma rutina
    push gs
    pop fs
    mov dl,2
    call blur
    pop fs

; ---- 4 plataformas antiguas (ES = DS: stosw)
    mov di,SITES
.si:
    call rand
    and ah,1Fh
    add ah,cl
    xchg al,ah
    xchg ax,bx
    mov al,80h                  ; centro de la punta: entre las 2x2 celdas del monolito
    mov ah,bl
    stosw
    mov ah,bh
    stosw
    mov al,[fs:bx]
    cmp al,WATER+6
    ja .p
    mov al,WATER+6
.p:
    sub bx,0303h                ; explanada de 8x8...
    mov dl,8
    mov ah,22
    call slab
    add bl,2                    ; ...y estrado de 4x4, del que nace el monolito
    sub bh,6
    add al,2
    mov [di+2],al
    mov dl,4
    mov ah,16
    call slab
    scasd                       ; DI += 4 (siguiente registro)
    add cl,64
    jnz .si

; ---- runas, sol, sombras guardianas (3 por plataforma) y eclipses
    mov si,ENTS
    mov cx,NRUNE
    mov al,2
    call spawn
    mov byte [ENTS+ESUN*8+4],6
    call revive

; ---- cámara: lejos de la primera plataforma, bajando del cielo; sol alto
    mov eax,[SITES]
    sub ah,24
    mov [V(camx)],eax
    mov byte [V(camf)+1],0C0h
    mov byte [V(sunh)],SUN0
%ifdef PRUEBA                   ; variante de prueba (monotest.asm)
    add byte [V(camx)+1],TESTDIST
    mov byte [V(runes)],TESTRUNES
    mov byte [V(built)],TESTBUILT
    mov byte [V(sunh)],TESTSUN
%endif
    pop es

; =========================================================== bucle
; ---- cuántos pasos de lógica tocan (0..8) desde el último fotograma
main:
    mov ax,[V(ticks)]
    mov cx,ax
    xchg cx,[V(last)]
    sub ax,cx
    cmp ax,8
    jbe .dt
    mov al,8
.dt:
    mov [V(dtk)],al
    or al,al
    jz render

; =========================================================== lógica (72,8 Hz)
logic:
; ---- andar (más lento en el agua) y girar; tecla pulsada = FFh
    mov cl,5
    call camcell
    cmp byte [fs:bx],WATER
    jne .dry
    inc cx
.dry:
    mov al,[K(50h)]
    or al,[K(1Fh)]
    sub al,[K(48h)]
    sub al,[K(11h)]
    jz .nomv
    add al,al
    cbw
    push ax
    imul word [V(cosv)]
    sar ax,cl
    add [V(camx)],ax
    pop ax
    imul word [V(sinv)]
    sar ax,cl
    add [V(camy)],ax
    inc byte [V(walk)]
.nomv:
    mov al,[K(4Bh)]
    or al,[K(1Eh)]
    sub al,[K(4Dh)]
    sub al,[K(20h)]
    cbw
    imul ax,ax,140h
    add [V(ang)],ax

; ---- disparar luz
    cmp byte [K(39h)],0
    je .nf
    mov si,ENTS+EBOLT*8
    cmp byte [si+4],0
    jne .nf
    mov word [si+4],6405h       ; tipo 5, vida 100
    mov eax,[V(camx)]
    mov [si],eax
    mov byte [V(recoil)],10
    mov ah,9
    call beep
.nf:

; ---- plataformas: activar con 3 runas, alzar el monolito
    mov si,SITES
.stl:
    mov al,[si+4]
    cmp al,1
    ja .sn
    je .rise
    call pdist
    cmp ax,300h
    jae .sn
    cmp byte [V(runes)],3
    jb .sn
    sub byte [V(runes)],3
    inc byte [si+4]
.rise:
    inc byte [si+5]
    call rand
    or ah,20h
    call beep
    mov bl,[si+1]
    mov bh,[si+3]
    mov di,bx
    mov al,[si+5]
    shr al,1
    add al,[si+6]
    mov ah,al                   ; obelisco de piedra (color del estrado)
    mov [fs:bx],ax
    mov [fs:bx+256],ax
    mov byte [V(shake)],3       ; la tierra tiembla...
    test byte [si+5],3
    jnz .nw
    mov ch,-12                  ; ...y despierta: se aclara en un círculo
.wy:
    mov cl,-12
.wx:
    mov al,cl
    imul al
    xchg ax,dx
    mov al,ch
    imul al
    add ax,dx
    cmp ax,144
    jae .wk
    mov bx,di
    add bl,cl
    add bh,ch
    cmp byte [gs:bx],116
    jae .wk
    inc byte [gs:bx]
.wk:
    inc cl
    cmp cl,12
    jl .wx
    inc ch
    cmp ch,12
    jl .wy
.nw:
    cmp byte [si+5],96          ; obelisco de 48 unidades
    jb .sn
    inc byte [si+4]
    inc byte [V(built)]
    mov byte [V(flash)],14
    mov byte [V(night)],0       ; un monolito a tiempo salva la noche
    mov byte [V(mel)],32        ; y suena un arpegio
    mov al,SUNUP
    call sunadd
.sn:
    add si,8
    jnz .stl

; ---- entidades: lógica
    mov si,ENTS
.e:
    call ent
    add si,8
    cmp si,ENTS+NENT*8
    jb .e

; ---- el tiempo: cada 512 pasos baja el sol; cada 1024 reaparecen sombras
    inc word [V(ltick)]
    mov al,[V(mel)]             ; arpegio: una nota cada 8 pasos
    test al,al
    jz .nm
    dec byte [V(mel)]
    test al,7
    jnz .nm
    mov ah,25
    mul ah
    add ax,400
    call beep
.nm:
    cmp byte [V(night)],0
    je .day
    dec byte [V(night)]
    jnz .tn
    push es                     ; noche cerrada: nace otra tierra
    jmp restart
.day:
    cmp byte [V(ltick)],0
    jne .tn
    test byte [V(ltick)+1],3
    jnz .ns
    call revive
.ns:
    cmp byte [V(built)],4
    je .tn
    test byte [V(ltick)+1],1    ; el sol baja cada 512 pasos (unos 7 s)
    jnz .tn
    dec byte [V(sunh)]
    jnz .tn
    mov byte [V(night)],255
.tn:
    dec byte [V(dtk)]
    jnz logic

; =========================================================== render
render:
    fild word [V(ang)]
    fmul dword [V(angk)]
    fsincos
    fimul word [V(c256)]
    fistp dword [V(cosv)]
    fimul word [V(c256)]
    fistp dword [V(sinv)]

; ---- altura de la cámara (suavizada, con balanceo al andar)
    call camcell
    movzx eax,byte [fs:bx]
    add ax,EYE
    test byte [V(walk)],32
    jz .wb
    inc ax
.wb:
    shl eax,8
    sub eax,[V(camf)]
    sar eax,3
    add [V(camf)],eax
    cmp byte [V(shake)],0       ; temblor mientras se alza un monolito
    je .nsh
    dec byte [V(shake)]
    call rand
    and ax,1FFh
    add [V(camf)],eax
.nsh:

; ---- cielo degradado + profundidad a 255
    xor di,di
    mov bx,-HOR
.sky:
    mov ax,bx
    cwd
    and ax,dx
    sar ax,1
    add al,FOG
    mov ah,al
    mov cx,160
    rep stosw
    inc bx
    cmp bx,200-HOR
    jl .sky
    push es
    push ds
    pop es
    xor di,di
    mov ax,-1
    mov cx,32000
    rep stosw
    pop es

; ---- terreno: un rayo por columna, de cerca a lejos
; ESI = (y<<16)|x en 8.8: una sola suma de 32 bits avanza el rayo
    and word [V(col)],0
.col:
    mov ax,[V(col)]
    sub ax,160
    mov cx,ax
    imul word [V(cosv)]
    mov al,ah
    mov ah,dl
    add ax,[V(sinv)]
    shl eax,16
    xchg eax,ecx
    imul word [V(sinv)]
    mov al,ah
    mov ah,dl
    neg ax
    add ax,[V(cosv)]
    cwde
    add eax,ecx
    mov [V(dir)],eax
    mov esi,[V(camx)]
    mov di,[V(col)]             ; DI = tope ya pintado de la columna
    add di,64000
    mov byte [V(step)],1
    xor ecx,ecx
    inc cx
.z:
    add esi,[V(dir)]
    mov ax,si
    mov ebx,esi
    shr ebx,16
    mov [V(fy)],bl              ; fracciones (los 3 bytes altos de fx y fy siempre a 0)
    mov bl,ah
    mov [V(fx)],al
    cmp cl,NEARZ
    jae .far
    call bilin                  ; cerca: altura bilineal (8.8)
    jmp short .h
.far:
    xor eax,eax                 ; lejos: celda más cercana
    mov ah,[fs:bx]
.h:
    neg eax
    add eax,[V(camf)]
    imul eax,[ecx*4+INV]
    sar eax,16
    add ax,HOR
    cmp ax,200
    jge .nx
    test ax,ax
    jns .p
    xor ax,ax
.p:
    imul ax,ax,320
    add ax,[V(col)]
    cmp ax,di
    jae .nx
    push ax
    mov al,[gs:bx]
    cmp cl,NEARZ
    jae .cf
    push fs                     ; cerca: color bilineal (la paleta es una rampa)
    push gs
    pop fs
    call bilin
    pop fs
    mov al,ah
.cf:
    pop dx
    mov bh,cl
    shr bh,2
    mov bl,al
    mov al,[cs:bx+FOGT]
.span:
    sub di,320
    mov [es:di],al
    mov [di],cl
    cmp di,dx
    ja .span
    cmp di,320
    jb .cd
.nx:
    add cl,[V(step)]            ; paso doble a partir de 64, 128 y 192
    jc .cd
    test cl,3Fh
    jnz .z
    shl byte [V(step)],1
    shl dword [V(dir)],1
    jmp .z
.cd:
    inc word [V(col)]
    cmp word [V(col)],320
    jb .col

; ---- entidades: dibujo
    mov si,ENTS
.d:
    movzx di,byte [si+4]
    test di,di
    jz .dn
    cmp di,6
    jne .dh
    mov eax,[V(camx)]           ; sol: siempre lejos; su altura es el tiempo
    add eax,SUNY*65536+SUNX
    mov [si],eax
    movzx eax,byte [V(sunh)]
    sub eax,8
    shl eax,8
    add eax,[V(camf)]
    jmp short .seth
.dh:
    mov bl,[si+1]
    mov bh,[si+3]
    movzx eax,byte [fs:bx]
    add al,[V(hover)+di-1]
    shl eax,8
    mov dx,[V(frame)]
    add dx,si
    and dl,7Fh
    sub dl,40h
    jns .ab
    neg dl
.ab:
    shl dl,2
    mov al,dl
.seth:
    mov [V(eh)],eax
    call proj                   ; (proj no toca DI: sigue siendo el tipo)
    jl .dn
    cmp di,6
    jne .dp
    mov byte [V(dep)],254       ; el sol, detrás de todo y sin niebla
.dp:
    movzx eax,byte [V(rads)+di-1]
    shl eax,20
    call rad
    mov [V(r)],ax
    mov al,[V(bases)+di-1]
    mov [V(base)],al
    mov al,[V(kks)+di-1]
    mov [V(kk)],al
    mov al,1                    ; sin estiramiento; sombreado invertido
    mov ah,[V(invt)+di-1]       ; (sombras y eclipses: núcleo oscuro, halo)
    mov [V(strc)],ax
    call disc
    cmp di,3                    ; la sombra mira: dos ojos brillantes
    jne .dn
    mov ax,[V(r)]               ; (solo de cerca: de lejos no son luces sueltas)
    cmp al,6
    jb .dn
    dec byte [V(dep)]
    mov cx,ax
    shr ax,2
    sub [V(sy)],ax
    shr cx,1
    shr ax,1
    sub cx,ax
    inc ax
    mov dx,(20<<8)|228
    sub [V(sx)],cx
    call orb
    add cx,cx
    add [V(sx)],cx
    call disc
.dn:
    add si,8
    cmp si,ENTS+NENT*8
    jb .d

; ---- haces: una elipse estirada que nace de la punta del monolito; corona si está alzado
    mov si,SITES
.bm:
    movzx eax,byte [si+5]
    shr ax,1
    add al,[si+6]
    adc ah,0
    shl eax,8
    mov [V(eh)],eax
    call proj
    jl .bmn
    mov dx,(24<<8)|146          ; dormido: luz tenue
    cmp byte [si+4],2
    jne .bh
    mov eax,7<<20               ; alzado: corona de luz...
    call rad
    mov dx,(46<<8)|204
    call orb
    mov dh,[V(frame)]           ; ...y haz que late
    and dh,15
    add dh,32
    mov dl,210
.bh:
    mov [V(base)],dx
    mov word [V(r)],2
    mov word [V(strc)],60
    sub word [V(sy)],120
    call disc
.bmn:
    add si,8
    jnz .bm

; ---- estrellas: aparecen según se pone el sol y giran con la vista
    mov cx,30
    sub cl,[V(sunh)]
    jbe .nost
    shl cx,4
.sr:
    imul ax,cx,9E37h
    mov dx,ax
    mov bx,[V(ang)]
    shr bx,5
    sub dx,bx
    and dx,7FFh
    cmp dx,320
    jae .sn2
    mov bl,ah
    and bx,3Fh
    imul bx,bx,320
    add bx,dx
    cmp byte [bx],255
    jne .sn2
    mov byte [es:bx],250
.sn2:
    loop .sr
.nost:

; ---- HUD: ranuras de runas
    mov di,6*320+8
    xor cx,cx
.hd:
    mov al,250
    cmp cl,[V(runes)]
    jb .hc
    mov al,150
    cmp cl,3
    jae .hx
.hc:
    mov ah,al
    mov bl,6
    push di
.hr:
    stosw
    stosw
    add di,316
    dec bl
    jnz .hr
    pop di
.hx:
    add di,8
    inc cx
    cmp cl,8
    jb .hd

; ---- el báculo de luz: asta sombreada que se balancea y cristal que late
    movzx bx,byte [V(walk)]
    and bl,63
    sub bl,32
    jns .w1
    neg bl
.w1:
    shr bl,3
    add bl,[V(recoil)]
    add bl,146
    mov [V(sy)],bx
    lea si,[bx+8]
.wr:
    mov ax,si
    sub ax,bx
    shr ax,1
    add ax,214-4
    imul di,si,320
    add di,ax
    mov cl,-4
.wc:
    mov al,cl
    inc ax
    imul al
    neg al
    add al,42
    stosb
    inc cl
    cmp cl,5
    jl .wc
    inc si
    cmp si,200
    jb .wr
    mov word [V(sx)],214
    movzx ax,byte [V(recoil)]
    shr al,1
    add al,11
    test byte [V(frame)],16
    jz .w2
    inc ax
.w2:
    mov byte [V(dep)],0
    mov dx,(46<<8)|200
    call orb
    cmp byte [V(recoil)],0
    je .w0
    dec byte [V(recoil)]
.w0:

; ---- sonido, destellos, paleta (la luz depende de la altura del sol)
    dec byte [V(snd)]
    jnz .q
    call spkoff
.q:
    mov al,[V(flash)]
    test al,al
    jz .f0
    dec byte [V(flash)]
.f0:
    add al,al
    mov bl,[V(sunh)]
    shr bl,2                    ; 32 = luz normal (sol a 60); de noche, luna (16)
    add bl,17
    cmp bl,36
    jbe .kb
    mov bl,36
.kb:
    add bl,al
    call setpal

; ---- volcar a la VGA tras el retrazado
    mov dx,3DAh
.vs:
    in al,dx
    test al,8
    jz .vs
    push ds
    push es
    pop ds
    push 0A000h
    pop es
    xor si,si
    xor di,di
    mov cx,16000
    rep movsd
    push ds
    pop es
    pop ds

; ---- mensajes: victoria o noche
    mov ax,msgw
    mov cx,19
    mov dx,020Ah
    cmp byte [V(built)],4
    je .say
    mov ax,msgn
    mov cl,12
    mov dl,14
    cmp byte [V(night)],0
    je .np
.say:
    push es
    push cs
    pop es
    push bp
    xchg ax,bp
    mov ax,1301h
    mov bx,00FFh
    int 10h
    pop bp
    pop es
.np:
    inc word [V(frame)]
    cmp byte [K(1)],0
    je main

; ---- salir (la pila de DOS guarda un 0: ret salta al int 20h del PSP)
    call swap
    mov ax,3
    int 10h
    ret

; =========================================================== rutinas

; intercambia los vectores 9 y 1Ch con los guardados (engancha o suelta teclado
; y reloj), alterna el PIT entre 72,8 y 18,2 Hz y apaga el altavoz; DS=ES=CS
swap:
    push 0
    pop ds
    mov eax,[V(v9)]
    xchg eax,[9*4]
    mov [V(v9)],eax
    mov eax,[V(v1c)]
    xchg eax,[1Ch*4]
    mov [V(v1c)],eax
    mov al,36h
    out 43h,al
    xor al,al
    out 40h,al
    xor byte [V(pit)],40h
    mov al,[V(pit)]
    out 40h,al
    push cs
    pop ds
    push cs
    pop es
spkoff:
    in al,61h
    and al,0FCh
    out 61h,al
    ret

; lógica de la entidad SI (un paso)
ent:
    mov al,[si+4]
    dec ax
    cmp al,1
    jbe .pick
    cmp al,3
    jbe .foe
    cmp al,4
    jne .r
    mov ax,[V(cosv)]            ; luz guiada: sigue la mirada
    sar ax,2
    add [si],ax
    mov ax,[V(sinv)]
    sar ax,2
    add [si+2],ax
    dec byte [si+5]
    jnz .r
    mov byte [si+4],0
.r:
    ret
.pick:
    call pdist                  ; runa o brasa: recoger
    cmp ax,0C0h
    jae .r
    xchg ah,[si+4]              ; (AH = 0: el hueco queda libre)
    dec ah
    jnz .rune
    mov byte [V(flash)],6       ; brasa: destello y el sol sube
    mov al,12
    call sunadd
    mov ah,2
    jmp beep
.rune:
    inc byte [V(runes)]         ; runa: nota cada vez más aguda
    movzx ax,byte [V(runes)]
    imul ax,ax,-150
    add ax,1500
    jmp beep
.foe:
    call pdist
    xchg ax,di                  ; DI = distancia
    mov eax,[V(camx)]
    cmp di,0A00h                ; sombra: perseguir de cerca o volver a casa
    jb .chase
    cmp byte [si+4],4           ; eclipse: te sigue por todo el mundo
    je .chase
    call post
.chase:
    movzx cx,byte [V(built)]    ; cada monolito los hace más rápidos
    add cx,cx
    add cl,8
    mov dx,si                   ; y cada una a su paso, para no fundirse
    shr dx,4
    and dx,6
    add cx,dx
    cmp byte [si+4],4
    jne .sp
    add cl,3
.sp:
    cmp di,300h                 ; a menos de 3 celdas se abalanzan
    jae .nl
    add cx,cx
.nl:
    sub ax,[si]
    sar ax,15
    or al,1
    imul ax,cx
    add [si],ax
    shr eax,16
    sub ax,[si+2]
    sar ax,15
    or al,1
    imul ax,cx
    add [si+2],ax
    mov di,ENTS+EBOLT*8         ; ¿le alcanza el orbe de luz?
    cmp byte [di+4],5
    jne .nob
    call edist
    cmp ax,0C0h
    jae .nob
    mov [di+4],ah
.kill:
    shr byte [si+4],2           ; la sombra se deshace; el eclipse deja una brasa
    mov ah,3
    jmp beep
.nob:
    mov di,SITES                ; santuario: un monolito alzado deshace a quien se acerca
.zs:
    cmp byte [di+4],2
    jne .zn
    call edist
    cmp ax,500h
    jb .kill
.zn:
    add di,8
    jnz .zs
    call pdist                  ; ¿te alcanza?
    cmp ax,80h
    jae .r
    mov byte [V(flash)],8
    mov ah,35
    call beep
    mov al,-6                   ; todo golpe roba sol; el eclipse, el doble
    cmp byte [si+4],4
    mov byte [si+4],0
    jne .grd
    add al,al
    jmp sunadd
.grd:
    call sunadd
    cmp byte [V(runes)],0       ; la sombra esconde una runa
    je .r
    dec byte [V(runes)]
    mov al,2
    jmp place

; EAX = valor bilineal (8.8) del mapa FS en la celda BX con fracciones fx, fy
bilin:
    call lerpx
    push eax
    inc bh
    call lerpx
    dec bh
    pop edx
    sub eax,edx
    imul eax,[V(fy)]
    sar eax,8
    add eax,edx
    ret

; EAX = h(BX)*256 + (h(BX+1)-h(BX))*fx   (interpolación en x)
lerpx:
    movzx eax,byte [fs:bx]
    movzx edx,byte [fs:bx+1]
    sub edx,eax
    imul edx,[V(fx)]
    shl eax,8
    add eax,edx
    ret

; rellena un cuadrado de DLxDL celdas desde BX con altura AL y color AH
slab:
    mov dh,dl
.y:
    push bx
    push dx
.x:
    mov [fs:bx],al
    mov [gs:bx],ah
    inc bl
    dec dl
    jnz .x
    pop dx
    pop bx
    inc bh
    dec dh
    jnz .y
    ret

; EAX = puesto de la sombra SI; BX = su plataforma (x8). Los bits de SI dan
; la plataforma (3-4) y el vértice del triángulo en torno al estrado (5-6)
post:
    mov bx,si
    and bx,18h
    mov eax,[bx+SITES]
    mov cx,si                   ; x: -3, 0, +3
    and cx,60h
    imul dx,cx,18h
    sub dx,300h
    add ax,dx
    ror eax,16
    and cx,20h                  ; y: -2, +3, -2
    imul dx,cx,28h
    sub dx,200h
    add ax,dx
    ror eax,16
    ret

; revive las sombras caídas en sus puestos (si su plataforma duerme) y los eclipses
revive:
    mov si,ENTS+GFIRST*8
.rs:
    cmp byte [si+4],0
    jne .rn
    call post
    cmp byte [bx+SITES+4],0
    jne .rn
    mov [si],eax
    mov byte [si+4],3
.rn:
    add si,8
    cmp si,ENTS+GEND*8
    jb .rs
    mov si,ENTS+HFIRST*8        ; los eclipses vuelven desde lejos
    mov cx,NHUNT
    mov al,4
; SI: CX entidades; los huecos libres pasan a tipo AL en tierra al azar
spawn:
    cmp byte [si+4],0
    jne .n
    call place
.n:
    add si,8
    loop spawn
    ret

; la entidad SI pasa a tipo AL en una celda de tierra al azar
place:
    push ax
.t:
    call rand
    xchg ax,bx
    cmp byte [fs:bx],WATER+2
    jb .t
    pop ax
    mov [si+4],al
    mov [si+1],bl
    mov [si+3],bh
    ret

; suma AL a la altura del sol, con tope
sunadd:
    add al,[V(sunh)]
    jg .a
    mov al,1
.a:
    cmp al,SUNMAX
    jbe .k
    mov al,SUNMAX
.k:
    mov [V(sunh)],al
    ret

; AX -> AL saturado a 0..255
clamp:
    test ah,ah
    jz .r
    sar ax,15
    not ax
.r:
    ret

; suaviza el mapa FS: DL pasadas de media de 4 vecinos (BX=0 a la entrada)
blur:
    mov al,[fs:bx-1]
    add al,[fs:bx+1]
    rcr al,1
    mov ah,[fs:bx-256]
    add ah,[fs:bx+256]
    rcr ah,1
    add al,ah
    rcr al,1
    mov [fs:bx],al
    inc bx
    jnz blur
    dec dl
    jnz blur
    ret

; suma la altura de la celda AX a SI
nadd:
    mov di,ax
    movzx di,byte [fs:di]
    add si,di
    ret

; EAX/AX = aleatorio (LCG de 32 bits, 16 bits altos)
rand:
    mov eax,[V(seed)]
    imul eax,eax,41C64E6Dh
    inc eax
    mov [V(seed)],eax
    shr eax,16
    ret

; BX = celda bajo la cámara
camcell:
    mov bl,[V(camx)+1]
    mov bh,[V(camy)+1]
    ret

; AX = distancia de Chebyshev entre [DI] y la entidad SI
edist:
    mov ax,[di]
    sub ax,[si]
    mov cx,[di+2]
    sub cx,[si+2]
    jmp short cheb

; AX = distancia de Chebyshev entre la cámara y la entidad SI
pdist:
    mov ax,[V(camx)]
    sub ax,[si]
    mov cx,[V(camy)]
    sub cx,[si+2]
; AX = max(|AX|,|CX|)
cheb:
    cwd
    xor ax,dx
    sub ax,dx
    xchg ax,cx
    cwd
    xor ax,dx
    sub ax,dx
    cmp ax,cx
    jae .r
    xchg ax,cx
.r:
    ret

; proyecta el punto [SI],[SI+2] (8.8) a altura [eh] con la FPU
; -> sx, sy, f (distancia en 16.16), dep; al volver, "jl" = detrás o a menos de 1 celda
proj:
    mov eax,[si]                ; tx, ty (el préstamo de x en y es 1/256 de celda)
    sub eax,[V(camx)]
    mov [V(tx)],eax
    fild word [V(tx)]           ; x
    fild word [V(ty)]           ; y x
    fld st1                     ; x y x
    fimul word [V(cosv)]
    fld st1                     ; y xc y x
    fimul word [V(sinv)]
    faddp st1                   ; F y x
    fist dword [V(f)]
    fxch st1                    ; y F x
    fimul word [V(cosv)]
    fxch st2                    ; x F yc
    fimul word [V(sinv)]
    fsubp st2                   ; F lado
    fdivp st1                   ; lado/F
    fimul word [V(c256)]
    fistp word [V(sx)]
    fild dword [V(camf)]
    fisub dword [V(eh)]
    fimul word [V(kv256)]
    fidiv dword [V(f)]
    fistp word [V(sy)]
    add word [V(sx)],160
    add word [V(sy)],HOR
    mov ax,[V(f)+2]
    mov [V(dep)],al
    cmp ax,1
    ret

; AX = EAX/f, con tope de 40 (radio en pantalla)
rad:
    cdq
    idiv dword [V(f)]
    cmp ax,40
    jbe .r
    mov ax,40
.r:
    ret

; esfera simple: radio AX, color base DL + luz DH
orb:
    mov [V(r)],ax
    mov [V(base)],dx
    mov word [V(strc)],1
; esfera sombreada en sx,sy de radio r; color base+kk*luz (luz invertida
; si invk=FFh); profundidad dep (254 o más: sin niebla)
disc:
    pusha
    movzx ax,byte [V(strc)]     ; estiramiento vertical (haz)
    mov bx,ax
    imul bx,bx
    mov [V(strq)],bx
    imul ax,[V(r)]
    mov [V(rv)],ax
    imul ax,ax
    mov [V(r2)],ax
    movzx ecx,ax
    test cx,cx
    jz .out
    movzx eax,byte [V(kk)]      ; kq = kk*65536/r2: luz sin dividir por píxel
    shl eax,16
    cdq
    div ecx
    mov [V(kq)],eax
    mov si,[V(rv)]
    neg si
.v:
    mov bx,[V(sy)]              ; filas fuera de pantalla: fuera
    add bx,si
    cmp bx,200
    jae .nr
    imul bx,bx,320
    mov [V(row)],bx
    mov di,[V(r)]
    neg di
.u:
    mov dx,[V(sx)]
    add dx,di
    cmp dx,320
    jae .s
    mov ax,si
    imul ax,ax
    mov cx,di
    imul cx,cx
    imul cx,[V(strq)]
    add cx,ax
    neg cx
    add cx,[V(r2)]
    jle .s
    movzx ecx,cx
    imul ecx,[V(kq)]
    shr ecx,16
    xchg ax,cx
    xor al,[V(invk)]
    add al,[V(base)]
    mov bl,al
    mov bh,[V(dep)]
    mov ah,bh
    cmp bh,254
    jae .nf
    shr bh,2
    mov al,[cs:bx+FOGT]
.nf:
    mov bx,[V(row)]
    add bx,dx
    cmp [bx],ah
    jbe .s
    mov [bx],ah
    mov [es:bx],al
.s:
    inc di
    cmp di,[V(r)]
    jle .u
.nr:
    inc si
    cmp si,[V(rv)]
    jle .v
.out:
    popa
    ret

; AX = divisor del PIT: pitido por el altavoz
beep:
    out 42h,al
    mov al,ah
    out 42h,al
    in al,61h
    or al,3
    out 61h,al
    mov byte [V(snd)],5
    ret

; paleta: 0-127 atardecer (índigo->malva->oro->crema) escalado por BL/32
; (la luz del sol); 128-255 luz cian, siempre igual de brillante
setpal:
    mov dx,3C8h
    xor cx,cx
    mov al,cl
    out dx,al
    inc dx
.l:
    mov al,cl
    and al,7Fh
    shr al,1
    test cl,cl
    js .k
    mul bl
    shr ax,5
    cmp ax,63
    jbe .k
    mov al,63
.k:
    mov bh,al
    mul al
    shr ax,6
    mov ah,bh
    test cl,cl
    js .s
    xchg al,ah
.s:
    out dx,al
    mov al,ah
    out dx,al
    mov al,bh
    shr al,1
    add al,16
    out dx,al
    inc cl
    jnz .l
    ret

; int 9: tabla de teclas pulsadas (FFh pulsada, 0 suelta)
kbd:
    push ax
    push bx
    in al,60h
    mov bl,al
    and bx,7Fh
    cmp al,80h
    salc
    mov [cs:keys+bx],al
    mov al,20h
    out 20h,al
    pop bx
    pop ax
    iret

; int 1Ch: reloj de la lógica
tmr:
    inc word [cs:ticks]
    iret

; ---- datos
msgw    db "LA TIERRA DESPIERTA"
msgn    db "LA NOCHE CAE"
; por tipo: brasa, runa, sombra, eclipse, luz, sol
rads    db 4, 5, 11, 9, 6, 160      ; radio en 1/16 de celda
bases   db 100, 196, 49, 123, 228, 96 ; color base (invertidos: base+kk+1)
kks     db 27, 58, 44, 92, 27, 31   ; rango de luz
hover   db 3, 4, 7, 9, 6, 0         ; altura sobre el suelo
invt    db 0, 0, 0FFh, 0FFh, 0, 0   ; sombreado invertido
angk    dd 9.5873799e-5             ; 2*pi/65536
c256    dw 256
kv256   dw KV*256
v9      dw kbd, 0                   ; vectores que swap intercambia con la IVT
v1c     dw tmr, 0
pit     db 0                        ; byte alto del divisor del PIT al enganchar

BPB     equ rads+127                ; BP: tablas, variables y teclas a 1 byte de desplazamiento

absolute $
bss0:
seed    resd 1
camf    resd 1
cosv    resd 1
sinv    resd 1
f       resd 1
eh      resd 1
dir     resd 1
fx      resd 1
fy      resd 1
camx    resw 1                  ; camx y camy contiguos: (y<<16)|x
camy    resw 1
ang     resw 1
col     resw 1
sx      resw 1
tx      resw 1                  ; tx y ty contiguos
ty      resw 1
sy      resw 1
r       resw 1
r2      resw 1
frame   resw 1
ticks   resw 1
last    resw 1
ltick   resw 1
base    resb 1                  ; base y kk contiguos
kk      resb 1
dep     resb 1
runes   resb 1
built   resb 1
flash   resb 1
snd     resb 1
walk    resb 1
step    resb 1
dtk     resb 1
sunh    resb 1
night   resb 1
recoil  resb 1
shake   resb 1
mel     resb 1
strc    resb 1                  ; strc e invk contiguos
invk    resb 1
strq    resw 1
rv      resw 1
row     resw 1
kq      resd 1
keys    resb 128
bss1:
