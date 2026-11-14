@ Diagnostic payload for the SM-T360 (rubenswifi).
@
@ Stock Samsung aboot loads the "kernel" section at 0x8000 and jumps to it.
@ This payload fills aboot's MDSS splash reservation green and then spins, so a
@ single flash answers one question nothing else on this tablet can: does the
@ bootloader execute the code we put in the kernel section at all?
@
@ The reservation is qcom,memblock-reserve = <0x03200000 0xFA0000> in the
@ stock DTB, i.e. FOUR 800x1280 32bpp frames of 0x3E8000 each. Painting only the
@ first frame proved nothing, because MDSS may be scanning frame 1, 2 or 3 -
@ so fill the entire reservation here.

	.syntax unified
	.arm

	b	realstart
	.space	0x3c			@ 0x04..0x40: zImage header patched by CI
realstart:
	ldr	r0, =0x03200000		@ start of the splash reservation
	ldr	r1, =0x041a0000		@ 0x03200000 + 0xFA0000 (all four frames)
	ldr	r2, =0xff00ff00		@ ARGB8888 green (bytes B=00 G=FF R=00 A=FF)
1:	str	r2, [r0], #4
	cmp	r0, r1
	blt	1b
2:	wfe
	b	2b
