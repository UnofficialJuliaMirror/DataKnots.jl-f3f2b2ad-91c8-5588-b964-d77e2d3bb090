#!/usr/bin/env julia

try
    using NarrativeTest
catch
    Pkg.clone("https://github.com/rbt-lang/NarrativeTest.jl")
end

# Make `print(Int)` produce identical output on 32-bit and 64-bit platforms.
Base.show_datatype(io::IO, ::Type{Int}) = print(io, "Int")

using QueryCombinators
using NarrativeTest
runtests()