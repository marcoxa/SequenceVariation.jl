"""
    Variation{S<:BioSequence,T<:BioSymbol}

A single change to a biological sequence. A general wrapper that can
represent a sequence-specific [`Substitution`](@ref),
[`Deletion`](@ref) or [`Insertion`](@ref). `Variation` is more robust
than [`Edit`](@ref), due to inclusion of the reference sequence and
built-in validation.

# Constructors

    Variation(ref::S, e::Edit{S,T}) where {S<:BioSequence,T<:BioSymbol}
    Variation(ref::S, edit::AbstractString) where {S<:BioSequence}

Generally speaking, the `Edit` constructor should be avoided to ensure
corectness: use of [`variations(::Haplotype)`](@ref) is encouraged,
instead.

Constructing a `Variation` from an `AbstractString` will parse the
from `edit` using the following syntax:
- Substitution: `"<REFBASE><POS><ALTBASE>"`, e.g. `"G16C"`
- Deletion: `"Δ<STARTPOS>-<ENDPOS>"`, e.g. `"Δ1-2"`
- Insertion: `"<POS><ALTBASES>"`, e.g. `"11T"`
"""
struct Variation{S<:BioSequence,T<:BioSymbol}
    ref::S
    edit::Edit{S,T}

    function Variation{S,T}(
        ref::S, e::Edit{S,T}, ::Unsafe
    ) where {S<:BioSequence,T<:BioSymbol}
        return new(ref, e)
    end
end

function Variation{S,T}(ref::S, e::Edit{S,T}) where {S<:BioSequence,T<:BioSymbol}
    v = Variation{S,T}(ref, e, Unsafe())
    return _is_valid(v) ? v : throw(ArgumentError("Invalid variant"))
end

Variation(ref::S, edit::Edit{S,T}) where {S,T} = Variation{S,T}(ref, edit)

function Variation(ref::S, edit::AbstractString) where {S<:BioSequence}
    T = eltype(ref)

    e = parse(Edit{S,T}, edit)
    return Variation{S,T}(ref, e)
end

function Haplotype(ref::S, vars::Vector{Variation{S,T}}) where {S<:BioSequence,T<:BioSymbol}
    edits = _edit.(vars)
    return Haplotype{S,T}(ref, edits)
end

"""
    reference(v::Variation)

Gets the reference sequence of `v`
"""
reference(v::Variation) = v.ref

"""
    _edit(v::Variation)

Gets the underlying [`Edit`](@ref) of `v`
"""
_edit(v::Variation) = v.edit

"""
    mutation(v::Variation)

Gets the underlying [`Substitution`](@ref), [`Insertion`](@ref), or [`Deletion`](@ref) of
`v`.
"""
mutation(v::Variation) = _mutation(_edit(v))
BioGenerics.leftposition(v::Variation) = leftposition(_edit(v))
BioGenerics.rightposition(v::Variation) = rightposition(_edit(v))
Base.:(==)(x::Variation, y::Variation) = x.ref == y.ref && x.edit == y.edit
Base.hash(x::Variation, h::UInt) = hash(Variation, hash((x.ref, x.edit), h))
function Base.isless(x::Variation, y::Variation)
    reference(x) == reference(y) ||
        error("Variations cannot be compared if their reference sequences aren't equal")
    return leftposition(x) < leftposition(y)
end

"""
    _is_valid(v::Variation)

Validate `v`. `v` is invalid if its opertation is out of bounds.
"""
function _is_valid(v::Variation)
    isempty(v.ref) && return false
    op = v.edit.x
    pos = v.edit.pos
    if op isa Substitution
        return pos in eachindex(v.ref)
    elseif op isa Insertion
        return pos in 0:(lastindex(v.ref) + 1)
    elseif op isa Deletion
        return pos in 1:(lastindex(v.ref) - length(op) + 1)
    end
end

function Base.show(io::IO, x::Variation)
    content = x.edit.x
    pos = x.edit.pos
    if content isa Substitution
        print(io, x.ref[pos], pos, content.x)
    elseif content isa Deletion
        print(io, 'Δ', pos, '-', pos + content.len - 1)
    elseif content isa Insertion
        print(io, pos, content.seq)
    else
        print(io, pos, content.x)
    end
end

function Base.in(v::Variation, var::Haplotype)
    if v.ref != var.ref
        error("References must be equal")
    end
    return any(v.edit == edit for edit in var.edits)
end

"""
    translate(var::Variation{S,T}, aln::PairwiseAlignment{S,S}) where {S,T}

Convert the difference in `var` to a new reference sequence based upon `aln`. `aln` is the
alignment of the old reference (`aln.b`) and the new reference sequence (`aln.seq`). Returns
the new [`Variation`](@ref).
"""
function translate(var::Variation{S,T}, aln::PairwiseAlignment{S,S}) where {S,T}
    kind = mutation(var)
    pos = leftposition(var)
    seq = sequence(aln)
    ref = aln.b

    # Special case: Insertions may have a pos of 0, which cannot be mapped to
    # the seq using ref2seq
    if iszero(pos)
        (s, r), _ = iterate(aln)
        (isgap(s) | isgap(r)) && return Inapplicable()
        return Variation{S,T}(seq, Edit{S,T}(Insertion(kind.seq), 0))
    end

    (seqpos, op) = BA.ref2seq(aln, pos)
    if kind isa Substitution
        # If it's a substitution, return nothing if it maps to a deleted
        # position, or substitutes to same base.
        op in (BA.OP_MATCH, BA.OP_SEQ_MATCH, BA.OP_SEQ_MISMATCH) || return nothing
        seq[seqpos] == kind.x && return nothing
        edit = Edit{S,T}(kind, seqpos)
        return Variation{S,T}(seq, edit, Unsafe())
    elseif kind isa Deletion
        # If it's a deletion, return nothing if the deleted part is already missing
        # from the new reference.
        (stop, op2) = BA.ref2seq(aln, pos + length(kind) - 1)
        start = seqpos + (op == BA.OP_DELETE)
        del_len = stop - start + 1
        del_len > 0 || return nothing
        edit = Edit{S,T}(Deletion(del_len), start)
        return Variation{S,T}(seq, edit, Unsafe())
    else
        # If it maps directly to a symbol, just insert
        if op in (BA.OP_MATCH, BA.OP_SEQ_MATCH, BA.OP_SEQ_MISMATCH)
            # This happens if there is already an insertion at the position
            if pos != lastindex(ref) && first(BA.ref2seq(aln, pos + 1)) != seqpos + 1
                return Inapplicable()
            else
                edit = Edit{S,T}(Insertion(mutation(var).seq), seqpos)
                return Variation{S,T}(seq, edit, Unsafe())
            end
            # Alternatively, it can map to a deletion. In that case, it become really
            # tricky to talk about the "same" insertion.
        else
            return Inapplicable()
        end
    end
end

"""
    variations(h::Haplotype{S,T}) where {S,T}

Converts the [`Edit`](@ref)s of `h` into a vector of [`Variation`](@ref)s.
"""
function variations(h::Haplotype{S,T}) where {S,T}
    vs = Vector{Variation{S,T}}(undef, length(_edits(h)))
    for (i, e) in enumerate(_edits(h))
        vs[i] = Variation{S,T}(reference(h), e)
    end
    return vs
end

"""
    refbases(v::Variation)

Get the reference bases of `v`. Note that for deletions, `refbases` also returns the base
_before_ the deletion in accordance with the `REF` field of the
[VCF v4 specification](https://samtools.github.io/hts-specs/VCFv4.3.pdf).
"""
function refbases(v::Variation)
    return _refbases(mutation(v), reference(v), leftposition(v))
end

"""
    altbases(v::Variation)

Get the alternate bases of `v`. Note that for insertions, `altbases` also returns the base
_before_ the insertion in accordance with the `ALT` field of the
[VCF v4 specification](https://samtools.github.io/hts-specs/VCFv4.3.pdf).
"""
function altbases(v::Variation)
    return _altbases(mutation(v), reference(v), leftposition(v))
end
