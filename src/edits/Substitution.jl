### -*- Mode: Julia -*-

### Substitution.jl
###
### Code representing substitutions.

"""
    Substitution

Represents the presence of a `T` at a given position. The position is
stored outside this struct.
"""
struct Substitution{T <: BioSymbol}
    x::T
end


### Interfaces extensions.

Base.length(::Substitution) = 1
Base.:(==)(x::Substitution, y::Substitution) = x.x == y.x
Base.hash(x::Substitution, h::UInt) = hash(Substitution, hash(x.x, h))


### Substitution functions.

function _refbases(::Substitution, reference::S, pos::UInt) where
    {S <: BioSequence}
    return S([reference[pos]])
end


function _altbases(s::Substitution, ::S, pos::UInt) where
    {S <: BioSequence}
    return S([s.x])
end

### Substitution.jl ends here.
