;
;	setup.s		(C) 1991 Linus Torvalds
;
; setup.s is responsible for getting the system data from the BIOS,
; and putting them into the appropriate places in system memory.
; both setup.s and system has been loaded by the bootblock.
;
; This code asks the bios for memory/disk/other parameters, and
; puts them in a "safe" place: 0x90000-0x901FF, ie where the
; boot-block used to be. It is then up to the protected mode
; system to read them from there before the area is overwritten
; for buffer-blocks.
;

; setup.s负责从BIOS获取系统数据，并将其放在系统内存的适当地方。此时setup.s和system已经被bootblock加载到内存中了
; 这段代码询问BIOS 内存、磁盘、其他参数，并将其放在安全的地方：0x90000-0x901FF，即 bootsect 曾在的地方。
; 然后在被缓冲区覆盖前，又收保护的系统读取

; NOTE; These had better be the same as in bootsect.s;

;gdt	global descriptor table				全局描述符表
;gdtr	global descriptor table register	全局描述符表寄存器
;lgdt	load global descriptor table		加载全局中断描述符表
;idt	int	descriptor table				中断描述符表

INITSEG  = 0x9000	; we move boot here - out of the way
SYSSEG   = 0x1000	; system loaded at 0x10000 (65536).
SETUPSEG = 0x9020	; this is the current segment

.globl begtext, begdata, begbss, endtext, enddata, endbss
.text
begtext:
.data
begdata:
.bss
begbss:
.text

entry start
start:

; ok, the read went well so we get current cursor position and save it for
; posterity.
; 我们得到了光标的当前位置，并保存了下来

	mov	ax,#INITSEG	; this is done in bootsect already, but...
	mov	ds,ax
	mov	ah,#0x03	; read cursor pos
	xor	bh,bh
	; int中断执行完毕后，dx寄存器里的值表示光标的位置，高8位dh存储行号，低8位dl存储列号
	int	0x10		; save it in known place, con_init fetches
	mov	[0],dx		; it from 0x90000. 	将光标位置放在0x90000处，控制台初始化时会来取

; Get memory size (extended mem, kB)	获取内存大小

	mov	ah,#0x88
	int	0x15
	mov	[2],ax

; Get video-card data:	获取显卡数据

	mov	ah,#0x0f
	int	0x10
	mov	[4],bx		; bh = display page
	mov	[6],ax		; al = video mode, ah = window width

; check for EGA/VGA and some config parameters	检查显示方式（EGA、VGA ）并获取一些配置参数

	mov	ah,#0x12
	mov	bl,#0x10
	int	0x10
	mov	[8],ax
	mov	[10],bx
	mov	[12],cx

; Get hd0 data	取第一个硬盘信息

	mov	ax,#0x0000
	mov	ds,ax
	lds	si,[4*0x41]
	mov	ax,#INITSEG
	mov	es,ax
	mov	di,#0x0080
	mov	cx,#0x10
	rep
	movsb

; Get hd1 data	取第二个硬盘信息

	mov	ax,#0x0000
	mov	ds,ax
	lds	si,[4*0x46]
	mov	ax,#INITSEG
	mov	es,ax
	mov	di,#0x0090
	mov	cx,#0x10
	rep
	movsb

; Check that there IS a hd1 :-)	检查是否存在第二个硬盘，如果不存在第二个表清0

	mov	ax,#0x01500
	mov	dl,#0x81
	int	0x13
	jc	no_disk1
	cmp	ah,#3
	je	is_disk1
no_disk1:
	mov	ax,#INITSEG
	mov	es,ax
	mov	di,#0x0090
	mov	cx,#0x10
	mov	ax,#0x00
	rep
	stosb
is_disk1:

; now we want to move to protected mode ...

	cli			; no interrupts allowed 关闭中断

; first we move the system to it's rightful place
; 把内存0x10000--0x90000内容，复制到0x00000处
	mov	ax,#0x0000
	cld			; 'direction'=0, movs moves forward
do_move:
	mov	es,ax		; destination segment
	add	ax,#0x1000
	cmp	ax,#0x9000
	jz	end_move
	mov	ds,ax		; source segment
	sub	di,di
	sub	si,si
	mov 	cx,#0x8000
	rep
	movsw
	jmp	do_move

; then we load the segment descriptors

end_move:
	mov	ax,#SETUPSEG	; right, forgot this at first. didn't work :-)
	mov	ds,ax
	lidt	idt_48		; load idt with 0,0
	lgdt	gdt_48		; load gdt with whatever appropriate	将gdt放在gdtr寄存器中

; that was painless, now we enable A20
; 打开A20寄存器，为了突破地址信号线20位的宽度，变成32位可用
	call	empty_8042
	mov	al,#0xD1		; command write
	out	#0x64,al
	call	empty_8042
	mov	al,#0xDF		; A20 on
	out	#0x60,al
	call	empty_8042

; well, that went ok, I hope. Now we have to reprogram the interrupts :-(
; we put them right after the intel-reserved hardware interrupts, at
; int 0x20-0x2F. There they won't mess up anything. Sadly IBM really
; messed this up with the original PC, and they haven't been able to
; rectify it afterwards. Thus the bios puts interrupts at 0x08-0x0f,
; which is used for the internal hardware interrupts as well. We just
; have to reprogram the 8259's, and it isn't fun.

; 嗯，我希望一切顺利。现在我们必须重新编程中断：-(
; 我们把它们放在intel保留硬件中断之后
; int 0x20-0x2F。在那里，他们不会搞砸任何事情。可悲的是，IBM真的
; 把这件事和原来的电脑搞砸了，他们还没能做到
; 事后纠正。因此，bios在0x08-0x0f处设置中断，
; 它也用于内部硬件中断。我们只是
; 必须重新编程8259（可编程中断控制器8259），这一点都不有趣。

	mov	al,#0x11		; initialization sequence
	out	#0x20,al		; send it to 8259A-1
	.word	0x00eb,0x00eb		; jmp $+2, jmp $+2
	out	#0xA0,al		; and to 8259A-2
	.word	0x00eb,0x00eb
	mov	al,#0x20		; start of hardware int's (0x20)
	out	#0x21,al
	.word	0x00eb,0x00eb
	mov	al,#0x28		; start of hardware int's 2 (0x28)
	out	#0xA1,al
	.word	0x00eb,0x00eb
	mov	al,#0x04		; 8259-1 is master
	out	#0x21,al
	.word	0x00eb,0x00eb
	mov	al,#0x02		; 8259-2 is slave
	out	#0xA1,al
	.word	0x00eb,0x00eb
	mov	al,#0x01		; 8086 mode for both
	out	#0x21,al
	.word	0x00eb,0x00eb
	out	#0xA1,al
	.word	0x00eb,0x00eb
	mov	al,#0xFF		; mask off all interrupts for now
	out	#0x21,al
	.word	0x00eb,0x00eb
	out	#0xA1,al

; well, that certainly wasn't fun :-(. Hopefully it works, and we don't
; need no steenking BIOS anyway (except for the initial loading :-).
; The BIOS-routine wants lots of unnecessary data, and it's less
; "interesting" anyway. This is how REAL programmers do it.
;
; Well, now's the time to actually move into protected mode. To make
; things as simple as possible, we do no register set-up or anything,
; we let the gnu-compiled 32-bit programs do that. We just jump to
; absolute address 0x00000, in 32-bit protected mode.

	mov	ax,#0x0001	; protected mode (PE) bit
	lmsw	ax		; This is it;
	jmpi	0,8		; jmp offset 0 of segment 8 (cs)
					; 跳转到内存地址的0处开始执行代码，0-0x80000 存放操作系统的所有代码

; This routine checks that the keyboard command queue is empty
; No timeout is used - if this hangs there is something wrong with
; the machine, and we probably couldn't proceed anyway.

; 此例程检查键盘命令队列是否为空
; 没有使用超时-如果挂起，说明设备出现问题，我们可能无论如何都无法继续。
empty_8042:
	.word	0x00eb,0x00eb
	in	al,#0x64	; 8042 status port
	test	al,#2		; is input buffer full?
	jnz	empty_8042	; yes - loop
	ret

gdt:
	.word	0,0,0,0		; dummy

	.word	0x07FF		; 8Mb - limit=2047 (2048*4096=8Mb)
	.word	0x0000		; base address=0
	.word	0x9A00		; code read/exec
	.word	0x00C0		; granularity=4096, 386

	.word	0x07FF		; 8Mb - limit=2047 (2048*4096=8Mb)
	.word	0x0000		; base address=0
	.word	0x9200		; data read/write
	.word	0x00C0		; granularity=4096, 386

idt_48:
	.word	0			; idt limit=0
	.word	0,0			; idt base=0L

gdt_48:
	.word	0x800		; gdt limit=2048, 256 GDT entries
	;全局表长2K字节，8字节组成一个端描述符项，共有256项
	.word	512+gdt,0x9	; gdt base = 0X9xxxx
	;4个字节构成的内存线性地址：0x0009<<16 + 0x0200 + gdt
	;即0x90200+gdt(即本程序中的gdt的偏移地址)
	
.text
endtext:
.data
enddata:
.bss
endbss:
