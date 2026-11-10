# demo.jl: usage of the IGEO7 stub binding. julia --project=. demo.jl (from this folder)
#
# the binding itself needs nothing but Base + Libdl; LibGEOS reads the WKB polygons,
# JSON3 writes a GeoJSON file to look at in QGIS etc. (both in this folder's Project.toml)
using Printf, Random
using JSON3, LibGEOS

include("IGEO7.jl")
using .IGEO7

const TARTU = (26.729, 58.378)

Grid(:IGEO7v2) do g
    println(g)

    # point -> cell -> centre + boundary
    ids = lonlat_to_z7(g, 9, [TARTU[1]], [TARTU[2]])
    z = ids[1]
    @printf("Tartu res 9: 0x%016x = %s, res %d\n", z, repr(z7_string(z)), z7_res(z))
    lon, lat = z7_to_centroid(g, ids)
    @printf("  centroid %.6f, %.6f\n", lon[1], lat[1])
    println("  boundary ", round.(z7_to_boundary(g, ids)[1]; digits = 6))
    @assert z7_parse(z7_string(z)) == z

    # the same point at every resolution: parent chain by string prefix
    chain = [z7_string(lonlat_to_z7(g, r, [TARTU[1]], [TARTU[2]])[1]) for r in 0:9]
    println("  res 0..9: ", join(chain, " "))

    # errors are exceptions, the context stays usable
    for (what, f) in [("lat 91", () -> lonlat_to_z7(g, 5, [0.0], [91.0])),
                      ("res 21", () -> lonlat_to_z7(g, 21, [0.0], [0.0])),
                      ("bad string", () -> z7_parse("002"))]
        try
            f()
        catch e
            e isa DggridError || rethrow()
            println("  $what -> ", e.msg)
        end
    end

    # topology, pure index arithmetic: neighbours (GBT), children, parent. k × n matrices
    nb = z7_neighbors(g, ids)[:, 1]
    println("  neighbours: ", join(z7_string.(nb), " "))
    kids = z7_children(g, ids)[:, 1]
    println("  children:   ", join(z7_string.(kids), " "))
    @assert all(==(z), z7_parent(g, kids)) && z7_parent(g, ids, 3)[1] == z7_parse(chain[4])
    pent = z7_parse("0800")
    println("  pentagon 0800 neighbours: ", [x == Z7_NONE ? "-" : z7_string(x) for x in vec(z7_neighbors(g, [pent]))])
    # 1-ring + 2-ring around the cell (dedupe, cell itself excluded)
    ring1 = Set(nb)
    ring2 = setdiff(Set(vec(z7_neighbors(g, nb))), ring1, (z, Z7_NONE))
    println("  ring 1: $(length(ring1)) cells, ring 2: $(length(ring2)) cells")

    # antimeridian cell, the 3 wrap modes
    am = lonlat_to_z7(g, 3, [180.0], [10.0])
    for mode in (:east, :west, :none)
        set_lon_wrap!(g, mode)
        r = z7_to_boundary(g, am)[1]
        @printf("  antimeridian cell, wrap %-4s: lon %8.3f .. %8.3f\n", mode, extrema(r[:, 1])...)
    end
    set_lon_wrap!(g, :east)

    # pole cells keep their 6 vertices at high resolution (patches/0003 on 9.2)
    pc = lonlat_to_z7(g, 18, [0.0, 0.0], [89.9999999, -89.9999999])
    println("  pole cells res 18: ", size.(z7_to_boundary(g, pc), 1), " vertices")

    # batch: 1M random points, uniform on the sphere
    rng = Xoshiro(42)
    n = 1_000_000
    plon = 360 .* rand(rng, n) .- 180
    plat = asind.(2 .* rand(rng, n) .- 1)
    lonlat_to_z7(g, 9, plon[1:10], plat[1:10])  # compile outside the timing
    t = @elapsed cells = lonlat_to_z7(g, 9, plon, plat)
    @printf("batch: %d pts -> res 9 in %.2fs (%.0fk pts/s), %d distinct cells\n", n, t, n / t / 1e3, length(unique(cells)))

    # ---- Arrow C Data Interface -> WKB / WKT, into LibGEOS ----
    wkt = z7_to_polygons_wkt(g, ids)
    println("wkt: ", first(wkt[1], 80), " ...")
    wkb = z7_to_polygons_wkb(g, cells[1:1000])
    geoms = LibGEOS.readgeom.(wkb)
    println("  LibGEOS: $(length(geoms)) polygons from WKB, all valid: $(all(LibGEOS.isValid, geoms))")

    # ---- GeoJSON: Tartu cell + ring 1 + ring 2 ----
    begin
        sel = vcat([z], collect(ring1), collect(ring2))
        rings = z7_to_boundary(g, sel)
        feats = map(eachindex(sel)) do i
            r = rings[i]
            coords = [[[r[k, 1], r[k, 2]] for k in vcat(1:size(r, 1), 1)]]  # close the ring
            Dict("type" => "Feature",
                 "properties" => Dict("z7" => z7_string(sel[i]), "ring" => i == 1 ? 0 : sel[i] in ring1 ? 1 : 2),
                 "geometry" => Dict("type" => "Polygon", "coordinates" => coords))
        end
        path = joinpath(@__DIR__, "tartu_rings.geojson")
        open(io -> JSON3.write(io, Dict("type" => "FeatureCollection", "features" => feats)), path, "w")
        println("geojson: $(length(feats)) cells -> $path")
    end
end
