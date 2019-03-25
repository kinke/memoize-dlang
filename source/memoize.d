module memoize;

import std.traits;

/**
The following code makes cached (memoized) property `f`
```
class {
    @property string _f() { ... }
    mixin CachedProperty!"f";
}
```
*/
mixin template CachedProperty(string name, string baseName = '_' ~ name) {
    mixin("private typeof(" ~ baseName ~ ") " ~ name ~ "Cache;");
    mixin("private bool " ~ name ~ "IsCached = false;");
    mixin("@property typeof(" ~ baseName ~ ") " ~ name ~ "() {\n" ~
          "if (" ~ name ~ "IsCached" ~ ") return " ~ name ~ "Cache;\n" ~
          name ~ "IsCached = true;\n" ~
          "return " ~ name ~ "Cache = " ~ baseName ~ ";\n" ~
          '}');
}

unittest {
    struct S {
        @property float _x() { return 1.5; }
        mixin CachedProperty!"x";
    }
    class C {
        @property float _x() { return 1.5; }
        mixin CachedProperty!"x";
    }
    S s;
    assert(s.x == 1.5);
    assert(s.x == 1.5);
    C c = new C();
    assert(c.x == 1.5);
}

private template _memoize(alias fun, string attr)
{
    import std.traits : ReturnType;
    // alias Args = Parameters!fun; // Bugzilla 13580

    ReturnType!fun _memoize(Parameters!fun args)
    {
        alias Args = Parameters!fun;
        import std.typecons : Tuple;

        mixin(attr ~ " static ReturnType!fun[Tuple!Args] memo;");
        auto t = Tuple!Args(args);
        if (auto p = t in memo)
            return *p;
        return memo[t] = fun(args);
    }
}

private template _memoize(alias fun, uint maxSize, string attr)
{
    import std.traits : ReturnType;
    // alias Args = Parameters!fun; // Bugzilla 13580
    ReturnType!fun _memoize(Parameters!fun args)
    {
        import std.traits : hasIndirections;
        import std.typecons : tuple;
        static struct Value { Parameters!fun args; ReturnType!fun res; }
        mixin(attr ~ " static Value[] memo;");
        mixin(attr ~ " static size_t[] initialized;");

        if (!memo.length)
        {
            import core.memory : GC;

            // Ensure no allocation overflows
            static assert(maxSize < size_t.max / Value.sizeof);
            static assert(maxSize < size_t.max - (8 * size_t.sizeof - 1));

            enum attr = GC.BlkAttr.NO_INTERIOR | (hasIndirections!Value ? 0 : GC.BlkAttr.NO_SCAN);
            memo = (cast(Value*) GC.malloc(Value.sizeof * maxSize, attr))[0 .. maxSize];
            enum nwords = (maxSize + 8 * size_t.sizeof - 1) / (8 * size_t.sizeof);
            initialized = (cast(size_t*) GC.calloc(nwords * size_t.sizeof, attr | GC.BlkAttr.NO_SCAN))[0 .. nwords];
        }

        import core.bitop : bt, bts;
        import std.conv : emplace;

        size_t hash;
        foreach (ref arg; args)
            hash = hashOf(arg, hash);
        // cuckoo hashing
        immutable idx1 = hash % maxSize;
        if (!bt(initialized.ptr, idx1))
        {
            emplace(&memo[idx1], args, fun(args));
            bts(initialized.ptr, idx1); // only set to initialized after setting args and value (bugzilla 14025)
            return memo[idx1].res;
        }
        else if (memo[idx1].args == args)
            return memo[idx1].res;
        // FNV prime
        immutable idx2 = (hash * 16_777_619) % maxSize;
        if (!bt(initialized.ptr, idx2))
        {
            emplace(&memo[idx2], memo[idx1]);
            bts(initialized.ptr, idx2); // only set to initialized after setting args and value (bugzilla 14025)
        }
        else if (memo[idx2].args == args)
            return memo[idx2].res;
        else if (idx1 != idx2)
            memo[idx2] = memo[idx1];

        memo[idx1] = Value(args, fun(args));
        return memo[idx1].res;
    }
}

/**
The same as in Phobos `std.functional`.
*/
alias memoize(alias fun) = _memoize!(fun, "");

/// ditto
alias memoize(alias fun, uint maxSize) = _memoize!(fun, maxSize, "");

/// must be locked explicitly!
alias sharedMemoize(alias fun) = _memoize!(fun, "shared");

/// must be locked explicitly!
alias sharedMemoize(alias fun, uint maxSize) = _memoize!(fun, maxSize, "shared");

template sychronizedMemoize(alias fun) {
    private alias impl = sharedMemoize!fun;
    synchronized ReturnType!fun sychronizedMemoize(Parameters!fun args) {
        return impl(args);
    }
}

template sychronizedMemoize(alias fun, uint maxSize) {
    private alias impl = sharedMemoize!(fun, maxSize);
    synchronized ReturnType!fun sychronizedMemoize(Parameters!fun args) {
        return impl(args);
    }
}

/**
Use it to memoize both a struct or class instance for a member function and function arguments like:
```
struct S {
    int f(int a, int b) {
        return a + b;
    }
}
alias f2 = memoizeMember!(S, "f");
alias f3 = memoizeMember!(S, "f", 10);
S s;
assert(f2(s, 2, 3) == 5);
```

As you see the member function name ("f" in the example) is passed as a string.
This is very unnatural, but I found no other way to do it.
*/
template memoizeMember(S, string name) {
    alias Member = __traits(getMember, S, name);
    ReturnType!Member f(S s, Parameters!Member others) {
        return __traits(getMember, s, name)(others);
    }
    alias memoizeMember = memoize!f;
}

/// ditto
template memoizeMember(S, string name, uint maxSize) {
    alias Member = __traits(getMember, S, name);
    ReturnType!Member f(S s, Parameters!Member others) {
        return __traits(getMember, s, name)(others);
    }
    alias memoizeMember = memoize!(f, maxSize);
}

unittest {
    struct S2 {
        int f(int a, int b) {
            return a + b;
        }
    }
    alias f2 = memoizeMember!(S2, "f");
    alias f3 = memoizeMember!(S2, "f", 10);
    S2 s;
    assert(f2(s, 2, 3) == 5);
    assert(f2(s, 2, 3) == 5);
    assert(f3(s, 2, 3) == 5);
}
