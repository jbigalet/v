import autogen.caps;
import std.stdio;
import std.conv;
import std.array;
import std.string;
import core.vararg;

/*
   Info about the terminfo compiled format are hard to find,
   as almost everyone uses ncurses / tic / infocmp / tput

   Most relevant stuff was found on:

    - terminfo(5)   [! the capacity list is sorted by alphabetical order,
                       not in order of appearance in a terminfo file ]
                    [ it probably is generated by ncurses/man/MKterminfo.sh, which sorts it ]
    - Terminfo Source Format (ENHANCED CURSE) on the Single UNIX Specification - opengroup.org
    - unibilium's header description (unibilium/secret/terminfo.pod)


    - tic's source (ncurses/include/tic.h) [ only available resource with the
                                             ordered capacity table? ]

    A lot of ncurses' terminfo handling code seem to be generated using ncurses/include/Caps file
    There are a bunch of awk / makefile / sh scripts using it in ncurses/ncurses/tinfo/ and in ncurses/man

    TODO a bit more doc
*/

// TODO terminfo extended capacities

struct Terminfo {
    struct Header {
        ushort magic;
        ushort name_size;
        ushort bool_count;
        ushort num_count;
        ushort string_count;
        ushort table_size;
    };

    Header header;
    string name;
    string description;
    bool[] bools;
    ushort[] nums;
    char[][] strings;
}

Terminfo parse_terminfo(string path) {
    File f = File(path, "r");
    Terminfo ti;
    f.rawRead((&ti.header)[0..1]);
    assert(ti.header.magic == octal!432);

    // name <=> term_name | [ ... | ] description
    char[] _name_section = new char[ti.header.name_size];
    f.rawRead(_name_section);
    string name_section = cast(string)_name_section;
    string[] splitted_name = name_section.split("|");
    assert(splitted_name.length >= 2);
    ti.name = splitted_name[0];
    ti.description = splitted_name[$-1][0..$-1];  // remove trailing \0

    ti.bools = new bool[ti.header.bool_count];
    f.rawRead(ti.bools);

    if((ti.header.name_size + ti.header.bool_count) % 2 != 0)
        f.seek(1, SEEK_CUR);  // padding

    ti.nums = new ushort[ti.header.num_count];
    f.rawRead(ti.nums);

    // string table

    ushort[] string_offsets = new ushort[ti.header.string_count];
    f.rawRead(string_offsets);
    char[] string_table = new char[ti.header.table_size];
    f.rawRead(string_table);
    ti.strings = new char[][ti.header.string_count];
    foreach(i, off; string_offsets)
        if(off != 0xffff) {
            assert(off < 0x7fff);
            long string_end = indexOf(string_table, '\0', off);
            if(off == string_end) {
                ti.strings[i] = new char[0];
            } else {
                assert(string_end > off,
                       format("index error %d, at %d, offset %u",
                              string_end, i, off));
                ti.strings[i] = string_table[off..string_end];
            }
        }

    return ti;
}

void print_term_caps(const ref Terminfo ti) {
    writeln("bools:");
    foreach(i, b; ti.bools)
        if(b)
            writefln("\t%s", cast(bool_caps)i);

    writeln();
    writeln("nums:");
    foreach(i, n; ti.nums)
        if(n != 0xffff)
            writefln("\t%s = %d", cast(num_caps)i, n);

    /* writeln(); */
    /* writeln("strings:"); */
    /* foreach(i, s; ti.strings) */
    /*     if(s.length != 0) */
    /*         writefln("\t%s = %s", cast(str_caps)i, ti.strings[i]); */
}


// TODO string cap interpretation only supports int args atm
// (xterm & rxvt only seem to need ints)
// but the spec allows string as arguments
// TODO 'u6' cap does a %d with nothing on the stack...

string _interpret_cap(string s, ref int[] stack, ref int[] args) {
    string o = "";
    uint i = 0;  // string index
    while(i < s.length) {
        char c = s[i++];
        if(c != '%') {
            o ~= c;
        } else {
            c = s[i++];
            switch(c) {
                case '%':
                    o ~= '%';
                    break;

                case 'd':
                    assert(stack.length > 0);
                    o ~= to!string(stack.back);
                    stack.popBack();
                    break;

                case 'p':
                    char n = s[i++];
                    assert(n >= '1' && n <= '9');
                    int arg_idx = (n - '1');
                    assert(arg_idx < args.length);
                    stack ~= args[arg_idx];
                    break;

                // TODO handle everything else
                default: assert(0);
            }
        }
    }
    return o;
}

string interpret_string_cap(ref Terminfo ti, str_caps cap, int[] args...) {
    // TODO asserts should also crash in release mode
    assert(cap < ti.header.string_count && ti.strings[cap].length > 0);
    string s = ti.strings[cap].idup;
    assert(s.indexOf('<') == -1);  // TODO
    assert(s.indexOf('^') == -1);  // TODO
    assert(s.indexOf("%s") == -1);  // TODO

    int[] stack;
    return _interpret_cap(s, stack, args);
}

void main(string[] args) {
    Terminfo ti = parse_terminfo("/usr/share/terminfo/r/rxvt-unicode-256color");
    /* print_term_caps(ti); */

    /* str_caps cap = str_caps.clear_screen; */
    str_caps cap = str_caps.parm_rindex;
    /* writeln(interpret_string_cap(ti, cap, 2).replace("\033", "\\033")); */
    write(interpret_string_cap(ti, cap, 3));

}
