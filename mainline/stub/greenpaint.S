@ Diagnostic payload for the SM-T360 (rubenswifi).
@
@ Stock Samsung aboot loads the "kernel" section at 0x8000 and jumps to it.
@ This payload paints aboot's own MDSS splash buffer green and then spins, so a
@ single flash answers one question that nothing else on this tablet can:
@ does the bootloader execute the code we put in the kernel section at all?
@
@ Zeros out everything else, so it cannot be mistaken for a kernel that ran and
@ crashed: if the screen turns green, our code ran and the panel is left
@ scanning out by aboot; if it stays black, aboot either never jumped here or
@ powered the display down at handoff.
@
@ Buffer geometry comes from the tablet's own MDSS device tree, not another
@ board's: qcom,memblock-reserve = <0x03200000 0xFA0000>, 800x1280, 32bpp,
@ stride 3200 -> one frame is 800*1280*4 = 0x3E8000 bytes.

	.syntax unified
	.arm

	b	realstart
	.space	0x3c			@ 0x04..0x40: zImage header patched by CI
realstart:
	ldr	r0, =0x03200000		@ start of aboot's splash buffer
	ldr	r1, =0x035e8000		@ 0x03200000 + 0x3E8000 (one 32bpp frame)
	ldr	r2, =0xff00ff00		@ ARGB8888 green (bytes B=00 G=FF R=00 A=FF)
1:	str	r2, [r0], #4
	cmp	r0, r1
	blt	1b
2:	wfe
	b	2b
