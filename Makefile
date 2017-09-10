DC := dmd
# DC := ldc

all:
	# $(DC) -wi -g -debug main.d
	$(DC) -wi -g -L-lX11 main.d

caps:  # TODO this is gore
	echo -n bool,num,str | xargs -I{} -d ',' sh -c "echo enum {}_caps { && sed -r -e '/STOP-HERE/,\$$d; s/([^\#\s]\S*)\t+\S+\t+{}\t+.*/\1,/;tx;d;:x; s/^/    /g' third-party/Caps && echo -e \"};\n"\" > autogen/caps.d

clean:
	rm -f main *.o
