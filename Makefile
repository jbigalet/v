DC := dmd
# DC := ldc

CFLAGS = -wi -g
LFLAGS = -L-lX11

SOURCES = autogen/keysym.d main.d

OBJECTS = $(patsubst %.d, %.o, $(SOURCES))


all: autogen/caps.d autogen/keysym.d $(OBJECTS) link

main.o: main.d
	$(DC) $(CFLAGS) -c $<

%.o: %.d
	$(DC) $(CFLAGS) -c $< -H -of$@

link:
	$(DC) $(LFLAGS) $(OBJECTS) -ofmain


clean:
	rm -f main *.o *.a *.di autogen/*


autogen/caps.d: third-party/Caps  # TODO this is gore  - Caps file is from ncurses/include/
	echo -n bool,num,str | xargs -I{} -d ',' sh -c "echo enum {}_caps { && sed -r -e '/STOP-HERE/,\$$d; s/([^\#\s]\S*)\t+\S+\t+{}\t+.*/\1,/;tx;d;:x; s/^/    /g' $< && echo -e \"};\n"\" > $@

autogen/keysym.d: third-party/keysymdef.h keysym.template # TODO not pretty - keysymdef.h file is from /usr/include/X11/
	echo -e "// !! DO NOT MODIFY !!\n // This file is automatically generated by 'make keysym'\n" > $@
	sed -r '/<KEYSYMDEF>/,$$d' keysym.template >> $@
	sed -r -e 's/^#define XK_([^ ]+)( +[^ ]+)/        \1 = \2,/;tx;d;:x s/^( +)([0-9]|function|union|cent)/\1_\2/' $< >> $@
	sed '0,/KEYSYMDEF/d' keysym.template >> $@

