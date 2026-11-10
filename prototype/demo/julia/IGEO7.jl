"""
IGEO7: stub Julia binding of the prototype DGGRID library (../../lib/include/dggrid.h).

Plain `ccall`, no compiler, no dependencies. The shared library is looked up in `_lib/`
next to this file (copied there by ../copy_libs.sh) or taken from `ENV["DGGRID_LIB"]`.
`include("IGEO7.jl")`, then `using .IGEO7`.

    Grid(:IGEO7v2) do g
        ids = lonlat_to_z7(g, 9, [26.729], [58.378])   # Vector{UInt64}
        z7_string(ids[1])                               # "0400..."
        lon, lat = z7_to_centroid(g, ids)
        rings = z7_to_boundary(g, ids)                  # [6×2 Matrix (lon, lat)]
        z7_neighbors(g, ids)                            # 6×n, column = one cell
    end
"""
module IGEO7

using Libdl

export Grid, DggridError, Z7_NONE, PRESETS,
    set_lon_wrap!, lonlat_to_z7, z7_to_centroid, z7_to_boundary,
    z7_res, z7_string, z7_parse,
    z7_parent, z7_children, z7_neighbors,
    z7_to_polygons_wkb, z7_to_polygons_wkt, z7_to_points_wkb

const PRESETS = (IGEO7v2 = 0, IGEO7v1 = 1, IVEA7HL = 2, IVEA7HS = 3)
const WRAP = (none = 0, east = 1, west = 2)
const PROJ = (ISEA = 0, IVEA = 1)
const DATUM = (AUTHALIC = 0, WGS84 = 1)
const ENCODING = (native = 0, interleaved = 1, wkb = 2, wkt = 3)
const MAX_RES = 20
"a pentagon's missing neighbour / child in the raw outputs"
const Z7_NONE = typemax(UInt64)

function _libpath()
    p = get(ENV, "DGGRID_LIB", "")
    isempty(p) || return p
    name = Sys.isapple() ? "libdggrid.dylib" : Sys.iswindows() ? "dggrid.dll" : "libdggrid.so"
    p = joinpath(@__DIR__, "_lib", name)
    isfile(p) || error("$p not found, run ../copy_libs.sh or set DGGRID_LIB")
    p
end

# a plain include, not a precompiled package -> a const path is fine for ccall((sym, lib))
const libdggrid = _libpath()
Libdl.dlopen(libdggrid)  # fail here, not at the first call

struct DggridError <: Exception
    msg::String
end
Base.showerror(io::IO, e::DggridError) = print(io, "DggridError: ", e.msg)

_lasterror(ctx::Ptr{Cvoid}) = unsafe_string(ccall((:dg_last_error, libdggrid), Cstring, (Ptr{Cvoid},), ctx))

"""
    Grid(preset::Symbol = :IGEO7v2)
    Grid(f, preset)                      # do-block, closed afterwards

One DGGRID context. `:IGEO7v2` (ISEA, WGS84), `:IGEO7v1` (ISEA, authalic, the 8.x IGEO7),
`:IVEA7HL`, `:IVEA7HS`. Not thread-safe, one per task / thread. Freed by `close` or the GC.
"""
mutable struct Grid
    ptr::Ptr{Cvoid}
    name::String
    function Grid(ptr::Ptr{Cvoid}, name::AbstractString)
        ptr == C_NULL && throw(DggridError(_lasterror(C_NULL)))
        finalizer(close, new(ptr, String(name)))
    end
end

Grid(preset::Symbol = :IGEO7v2) =
    Grid(ccall((:dg_preset_new, libdggrid), Ptr{Cvoid}, (Cint,), PRESETS[preset]), string(preset))

"""
    Grid(proj, datum, vert0_lon = 11.2, vert0_lat = NaN, azimuth = 0.0)

Another icosahedron orientation, `proj` `:ISEA` / `:IVEA`, `datum` `:WGS84` / `:AUTHALIC`.
`vert0_lat` NaN = the exact icosahedron vertex latitude.
"""
function Grid(proj::Symbol, datum::Symbol, vert0_lon::Real = 11.2, vert0_lat::Real = NaN, azimuth::Real = 0.0)
    p = ccall((:dg_ctx_new, libdggrid), Ptr{Cvoid}, (Cint, Cint, Cdouble, Cdouble, Cdouble),
        PROJ[proj], DATUM[datum], vert0_lon, vert0_lat, azimuth)
    Grid(p, "$proj/$datum/$vert0_lon")
end

function Grid(f::Function, args...)
    g = Grid(args...)
    try
        f(g)
    finally
        close(g)
    end
end

function Base.close(g::Grid)
    if g.ptr != C_NULL
        ccall((:dg_ctx_free, libdggrid), Cvoid, (Ptr{Cvoid},), g.ptr)
        g.ptr = C_NULL
    end
    nothing
end

Base.show(io::IO, g::Grid) = print(io, "Grid(", g.name, g.ptr == C_NULL ? ", closed)" : ")")

function _ctx(g::Grid)
    g.ptr == C_NULL && throw(DggridError("Grid is closed"))
    g.ptr
end

_check(g::Grid, rc, fn) = rc == 0 || throw(DggridError("$fn: $(_lasterror(g.ptr))"))

"""
    set_lon_wrap!(g, mode)

Polygon longitudes across the antimeridian: `:east` (default, lon > 180), `:west`, `:none`
(CLI WRAP, every vertex in [-180, 180]).
"""
set_lon_wrap!(g::Grid, mode::Symbol) =
    (_check(g, ccall((:dg_ctx_set_lon_wrap, libdggrid), Cint, (Ptr{Cvoid}, Cint), _ctx(g), WRAP[mode]),
        "dg_ctx_set_lon_wrap"); g)

# ---- plain API ----

"cells containing the points (degrees) at resolution `res` 0..20"
function lonlat_to_z7(g::Grid, res::Integer, lon::AbstractVector{<:Real}, lat::AbstractVector{<:Real})
    length(lon) == length(lat) || throw(DimensionMismatch("lon and lat lengths differ"))
    x, y = convert(Vector{Float64}, lon), convert(Vector{Float64}, lat)
    out = Vector{UInt64}(undef, length(x))
    rc = ccall((:dg_geo_to_z7, libdggrid), Cint,
        (Ptr{Cvoid}, Cint, Ptr{Cdouble}, Ptr{Cdouble}, Csize_t, Ptr{UInt64}), _ctx(g), res, x, y, length(x), out)
    _check(g, rc, "dg_geo_to_z7")
    out
end

_ids(ids) = convert(Vector{UInt64}, ids)

"cell centres `(lon, lat)`, resolution taken from each id"
function z7_to_centroid(g::Grid, ids::AbstractVector{<:Integer})
    z = _ids(ids)
    lon, lat = Vector{Float64}(undef, length(z)), Vector{Float64}(undef, length(z))
    rc = ccall((:dg_z7_to_centroid, libdggrid), Cint,
        (Ptr{Cvoid}, Ptr{UInt64}, Csize_t, Ptr{Cdouble}, Ptr{Cdouble}), _ctx(g), z, length(z), lon, lat)
    _check(g, rc, "dg_z7_to_centroid")
    lon, lat
end

"cell boundaries, one `nverts × 2` matrix (lon, lat) per id, open ring, 6 vertices (5 for pentagons)"
function z7_to_boundary(g::Grid, ids::AbstractVector{<:Integer})
    z = _ids(ids)
    ll = Matrix{Float64}(undef, 12, length(z))  # column i = lon1 lat1 lon2 lat2 .. of cell i
    nv = Vector{UInt8}(undef, length(z))
    rc = ccall((:dg_z7_to_boundary, libdggrid), Cint,
        (Ptr{Cvoid}, Ptr{UInt64}, Csize_t, Ptr{Cdouble}, Ptr{UInt8}), _ctx(g), z, length(z), ll, nv)
    _check(g, rc, "dg_z7_to_boundary")
    [permutedims(reshape(ll[1:2nv[i], i], 2, :)) for i in eachindex(z)]
end

# ---- Z7 helpers, no context ----

"resolution of a Z7 id, -1 if invalid"
z7_res(z::Integer) = Int(ccall((:dg_z7_res, libdggrid), Cint, (UInt64,), z))

"Z7 digit string, e.g. \"0401234\" (2-digit base cell + one digit per resolution)"
function z7_string(z::Integer)
    buf = Vector{UInt8}(undef, 32)
    n = ccall((:dg_z7_to_string, libdggrid), Cint, (UInt64, Ptr{UInt8}, Csize_t), z, buf, length(buf))
    n < 0 && throw(DggridError("invalid Z7 index 0x$(string(UInt64(z), base = 16, pad = 16))"))
    String(buf[1:n])
end

"Z7 digit string -> id"
function z7_parse(s::AbstractString)
    out = Ref{UInt64}()
    rc = ccall((:dg_z7_from_string, libdggrid), Cint, (Cstring, Csize_t, Ref{UInt64}), s, ncodeunits(s), out)
    rc == 0 || throw(DggridError("invalid Z7 string $(repr(s))"))
    out[]
end

# ---- Z7 topology, pure index arithmetic, the same for every preset ----
# the C side writes out[k * i + j] -> a k × n Julia matrix, column i = cell i

function _slots(g::Grid, fn::Symbol, ids, k::Int, extra...)
    z = _ids(ids)
    out = Matrix{UInt64}(undef, k, length(z))
    rc = if fn === :dg_z7_parent
        ccall((:dg_z7_parent, libdggrid), Cint, (Ptr{Cvoid}, Ptr{UInt64}, Csize_t, Cint, Ptr{UInt64}),
            _ctx(g), z, length(z), extra[1], out)
    elseif fn === :dg_z7_children
        ccall((:dg_z7_children, libdggrid), Cint, (Ptr{Cvoid}, Ptr{UInt64}, Csize_t, Ptr{UInt64}),
            _ctx(g), z, length(z), out)
    else
        ccall((:dg_z7_neighbors, libdggrid), Cint, (Ptr{Cvoid}, Ptr{UInt64}, Csize_t, Ptr{UInt64}),
            _ctx(g), z, length(z), out)
    end
    _check(g, rc, String(fn))
    out
end

"ancestors at resolution `res`, -1 = one level up"
z7_parent(g::Grid, ids::AbstractVector{<:Integer}, res::Integer = -1) = vec(_slots(g, :dg_z7_parent, ids, 1, res))

"7 × n children in digit order, a pentagon's skipped digit = `Z7_NONE`"
z7_children(g::Grid, ids::AbstractVector{<:Integer}) = _slots(g, :dg_z7_children, ids, 7)

"6 × n edge neighbours in GBT direction order 1..6, a pentagon's missing one = `Z7_NONE`"
z7_neighbors(g::Grid, ids::AbstractVector{<:Integer}) = _slots(g, :dg_z7_neighbors, ids, 6)

# ---- Arrow C Data Interface, by hand (dggrid_arrow.h) ----
# Arrow.jl reads IPC, not the C Data Interface -> the two structs are mirrored here. Input:
# a uint64 array borrowed for the call (Julia owns the memory). Output: geoarrow.wkb /
# geoarrow.wkt (binary / utf8, int32 offsets), copied into Julia vectors, then released.

mutable struct ArrowSchema
    format::Ptr{UInt8}
    name::Ptr{UInt8}
    metadata::Ptr{UInt8}
    flags::Int64
    n_children::Int64
    children::Ptr{Ptr{Cvoid}}
    dictionary::Ptr{Cvoid}
    release::Ptr{Cvoid}
    private_data::Ptr{Cvoid}
end
ArrowSchema() = ArrowSchema(C_NULL, C_NULL, C_NULL, 0, 0, C_NULL, C_NULL, C_NULL, C_NULL)

mutable struct ArrowArray
    length::Int64
    null_count::Int64
    offset::Int64
    n_buffers::Int64
    n_children::Int64
    buffers::Ptr{Ptr{Cvoid}}
    children::Ptr{Ptr{Cvoid}}
    dictionary::Ptr{Cvoid}
    release::Ptr{Cvoid}
    private_data::Ptr{Cvoid}
end
ArrowArray() = ArrowArray(0, 0, 0, 0, 0, C_NULL, C_NULL, C_NULL, C_NULL, C_NULL)

# release of a borrowed input: nothing to free, mark released. nanoarrow rejects release NULL
_release_offset(T) = fieldoffset(T, findfirst(==(:release), fieldnames(T)))
_release_borrowed(p::Ptr{T}) where {T} = (unsafe_store!(Ptr{Ptr{Cvoid}}(p + _release_offset(T)), C_NULL); nothing)
const _RELEASE_SCHEMA = Ref{Ptr{Cvoid}}(C_NULL)
const _RELEASE_ARRAY = Ref{Ptr{Cvoid}}(C_NULL)
_RELEASE_SCHEMA[] = @cfunction(_release_borrowed, Cvoid, (Ptr{ArrowSchema},))
_RELEASE_ARRAY[] = @cfunction(_release_borrowed, Cvoid, (Ptr{ArrowArray},))

const _FMT_UINT64 = "L"

# call fn(schema_in, array_in, schema_out, array_out) -> Int32 rc, on a borrowed uint64 array
function _with_z7_array(f, ids::Vector{UInt64})
    bufs = Ptr{Cvoid}[C_NULL, pointer(ids)]  # no validity bitmap, values
    GC.@preserve ids bufs _FMT_UINT64 begin
        s = ArrowSchema(pointer(_FMT_UINT64), C_NULL, C_NULL, 0, 0, C_NULL, C_NULL, _RELEASE_SCHEMA[], C_NULL)
        a = ArrowArray(length(ids), 0, 0, 2, 0, pointer(bufs), C_NULL, C_NULL, _RELEASE_ARRAY[], C_NULL)
        f(s, a)
    end
end

# binary / utf8 output (+ large variants) -> Vector{Union{Missing, Vector{UInt8}}}
function _read_binary(s::ArrowSchema, a::ArrowArray)
    fmt = unsafe_string(s.format)
    fmt in ("z", "u", "Z", "U") || throw(DggridError("unexpected Arrow format $(repr(fmt))"))
    O = fmt in ("Z", "U") ? Int64 : Int32
    bufs = unsafe_wrap(Array, a.buffers, a.n_buffers)
    validity, offsets, data = Ptr{UInt8}(bufs[1]), Ptr{O}(bufs[2]), Ptr{UInt8}(bufs[3])
    out = Vector{Union{Missing, Vector{UInt8}}}(undef, a.length)
    for i in 1:a.length
        j = a.offset + i - 1
        if validity != C_NULL && a.null_count != 0 && (unsafe_load(validity, j ÷ 8 + 1) >> (j % 8)) & 1 == 0
            out[i] = missing
        else
            lo, hi = unsafe_load(offsets, j + 1), unsafe_load(offsets, j + 2)
            out[i] = unsafe_wrap(Array, data + lo, hi - lo) |> copy
        end
    end
    out
end

_release(s::ArrowSchema, a::ArrowArray) = begin
    ccall((:dg_arrow_release_array, libdggrid), Cvoid, (Ref{ArrowArray},), a)
    ccall((:dg_arrow_release_schema, libdggrid), Cvoid, (Ref{ArrowSchema},), s)
end

function _geometry_out(g::Grid, fn::Symbol, ids, encoding::Symbol)
    os, oa = ArrowSchema(), ArrowArray()
    rc = _with_z7_array(_ids(ids)) do s, a
        if fn === :dg_arrow_z7_to_polygons
            ccall((:dg_arrow_z7_to_polygons, libdggrid), Cint,
                (Ptr{Cvoid}, Ref{ArrowSchema}, Ref{ArrowArray}, Cint, Ref{ArrowSchema}, Ref{ArrowArray}),
                _ctx(g), s, a, ENCODING[encoding], os, oa)
        else
            ccall((:dg_arrow_z7_to_points, libdggrid), Cint,
                (Ptr{Cvoid}, Ref{ArrowSchema}, Ref{ArrowArray}, Cint, Ref{ArrowSchema}, Ref{ArrowArray}),
                _ctx(g), s, a, ENCODING[encoding], os, oa)
        end
    end
    _check(g, rc, String(fn))
    try
        _read_binary(os, oa)
    finally
        _release(os, oa)
    end
end

"cell polygons as WKB (closed rings, longitudes per `set_lon_wrap!`), via the Arrow C API"
z7_to_polygons_wkb(g::Grid, ids) = _geometry_out(g, :dg_arrow_z7_to_polygons, ids, :wkb)
"cell polygons as WKT strings"
z7_to_polygons_wkt(g::Grid, ids) = [String(x) for x in _geometry_out(g, :dg_arrow_z7_to_polygons, ids, :wkt)]
"cell centres as WKB points"
z7_to_points_wkb(g::Grid, ids) = _geometry_out(g, :dg_arrow_z7_to_points, ids, :wkb)

end # module
