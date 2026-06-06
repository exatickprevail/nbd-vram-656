all: nbd-vram

nbd-vram: nbd-vram.c
	gcc -O2 -Wall -o nbd-vram nbd-vram.c -ldl

clean:
	rm -f nbd-vram

install: nbd-vram
	@echo "Use install.sh for full installation"
