using Makie:
    NoConversion,
    convert_arguments,
    conversion_trait,
    convert_single_argument,
    to_vertices,
    categorical_colors

@testset "Conversions" begin
    # NoConversion
    struct NoConversionTestType end
    conversion_trait(::NoConversionTestType) = NoConversion()

    let nctt = NoConversionTestType(),
        ncttt = conversion_trait(nctt)
        @test convert_arguments(ncttt, 1, 2, 3) == (1, 2, 3)
    end

end

@testset "changing input types" begin
    input = Observable{Any}(decompose(Point2f, Circle(Point2f(0), 2f0)))
    f, ax, pl = mesh(input)
    m = Makie.triangle_mesh(Circle(Point2f(0), 1f0))
    input[] = m
    @test pl[1][] == m
end

@testset "to_vertices" begin
    X1 = [Point(rand(3)...) for i = 1:10]
    V1 = to_vertices(X1)
    @test Float32(X1[7][1]) == V1[7][1]

    X2 = [tuple(rand(3)...) for i = 1:10]
    V2 = to_vertices(X2)
    @test Float32(X2[7][1]) == V2[7][1]

    X4 = rand(2,10)
    V4 = to_vertices(X4)
    @test Float32(X4[1,7]) == V4[7][1]
    @test V4[7][3] == 0

    X5 = rand(3,10)
    V5 = to_vertices(X5)
    @test Float32(X5[1,7]) == V5[7][1]

    X6 = rand(10,2)
    V6 = to_vertices(X6)
    @test Float32(X6[7,1]) == V6[7][1]
    @test V6[7][3] == 0

    X7 = rand(10,3)
    V7 = to_vertices(X7)
    @test Float32(X7[7,1]) == V7[7][1]
end

@testset "GeometryBasics Lines & Polygons" begin
    pts = [Point(1, 2), Point(4, 5), Point(10, 8), Point(1, 2)]
    ls = LineString(pts)
    p = convert_arguments(Makie.PointBased(), ls)
    @test p[1] == pts

    pts_empty = Point2f[]
    ls_empty = LineString(pts_empty)
    p_empty = convert_arguments(Makie.PointBased(), ls_empty)
    @test p_empty[1] == pts_empty

    pts1 = [Point(5, 2), Point(4, 8), Point(2, 8), Point(5, 2)]
    ls1 = LineString(pts1)
    lsa = [ls, ls1]
    p1 = convert_arguments(Makie.PointBased(), lsa)
    @test p1[1][1:4] == pts
    @test p1[1][6:9] == pts1

    mls = MultiLineString(lsa)
    p2 = convert_arguments(Makie.PointBased(), mls)
    @test p2[1][1:4] == pts
    @test p2[1][6:9] == pts1

    mls_emtpy = MultiLineString([LineString(pts_empty)])
    p_empty = convert_arguments(Makie.PointBased(), mls_emtpy)
    @test p_empty[1] == pts_empty

    pol_e = Polygon(ls)
    p3_e = convert_arguments(Makie.PointBased(), pol_e)
    @test p3_e[1][1:end] == pts # for poly we repeat last point

    pol = Polygon(ls, [ls1])
    p3 = convert_arguments(Makie.PointBased(), pol)
    @test p3[1][1:4] == pts
    @test p3[1][6:9] == pts1

    pol_emtpy = Polygon(pts_empty)
    p_empty = convert_arguments(Makie.PointBased(), pol_emtpy)
    @test p_empty[1] == pts_empty

    pts2 = Point{2,Int}[(5, 1), (3, 3), (4, 8), (1, 2), (5, 1)]
    pts3 = Point{2,Int}[(2, 2), (2, 3), (3, 4), (2, 2)]
    pts4 = Point{2,Int}[(2, 2), (3, 8), (5, 6), (3, 4), (2, 2)]
    ls2 = LineString(pts2)
    ls3 = LineString(pts3)
    ls4 = LineString(pts4)
    pol1 = Polygon(ls2, [ls3, ls4])
    apol = [pol, pol1]
    p4 = convert_arguments(Makie.PointBased(), apol)
    mpol = MultiPolygon([pol, pol1])
    @test p4[1][1:4] == pts
    @test p4[1][6:9] == pts1
    @test p4[1][11:15] == pts2
    @test p4[1][17:20] == pts3
    @test p4[1][22:end] == pts4

    mpol_emtpy = MultiPolygon(typeof(pol_emtpy)[])
    p_empty = convert_arguments(Makie.PointBased(), mpol_emtpy)
    @test p_empty[1] == pts_empty
end

@testset "functions" begin
    x = -pi..pi
    s = convert_arguments(Lines, x, sin)
    xy = s.args[1]
    @test xy[1][1] ≈ -pi
    @test xy[end][1] ≈ pi
    for (val, fval) in xy
        @test fval ≈ sin(val) atol=1f-6
    end

    x = range(-pi, stop=pi, length=100)
    s = convert_arguments(Lines, x, sin)
    xy = s.args[1]
    @test xy[1][1] ≈ -pi
    @test xy[end][1] ≈ pi
    for (val, fval) in xy
        @test fval ≈ sin(val) atol=1f-6
    end
end

using Makie: check_line_pattern, line_diff_pattern

@testset "Linetype" begin
    @test isnothing(check_line_pattern("-."))
    @test isnothing(check_line_pattern("--"))
    @test_throws ArgumentError check_line_pattern("-.*")

    # for readability, the length of dash and dot
    dash, dot = 3.0, 1.0

    @test line_diff_pattern(:dash)             ==
          line_diff_pattern("-",   :normal)    == [dash, 3.0]
    @test line_diff_pattern(:dot)              ==
          line_diff_pattern(".",   :normal)    == [dot, 2.0]
    @test line_diff_pattern(:dashdot)          ==
          line_diff_pattern("-.",  :normal)    == [dash, 3.0, dot, 3.0]
    @test line_diff_pattern(:dashdotdot)       ==
          line_diff_pattern("-..", :normal)    == [dash, 3.0, dot, 2.0, dot, 3.0]

    @test line_diff_pattern(:dash, :loose)     == [dash, 6.0]
    @test line_diff_pattern(:dot,  :loose)     == [dot, 4.0]
    @test line_diff_pattern("-",   :dense)     == [dash, 2.0]
    @test line_diff_pattern(".",   :dense)     == [dot, 1.0]
    @test line_diff_pattern(:dash, 0.5)        == [dash, 0.5]
    @test line_diff_pattern(:dot,  0.5)        == [dot, 0.5]
    @test line_diff_pattern("-",   (0.4, 0.6)) == [dash, 0.6]
    @test line_diff_pattern(:dot,  (0.4, 0.6)) == [dot, 0.4]
    @test line_diff_pattern("-..", (0.4, 0.6)) == [dash, 0.6, dot, 0.4, dot, 0.6]

    # gaps must be Symbol, a number, or two numbers
    @test_throws ArgumentError line_diff_pattern(:dash, :NORMAL)
    @test_throws ArgumentError line_diff_pattern(:dash, ())
    @test_throws ArgumentError line_diff_pattern(:dash, (1, 2, 3))
end

struct MyVector{T}
    v::Vector{T}
end

struct MyNestedVector{T}
    v::MyVector{T}
end

@testset "single conversions" begin
    myvector = MyVector(collect(1:10))
    mynestedvector = MyNestedVector(MyVector(collect(11:20)))
    @test_throws ErrorException convert_arguments(Lines, myvector, mynestedvector)

    Makie.convert_single_argument(v::MyNestedVector) = v.v
    Makie.convert_single_argument(v::MyVector) = v.v

    @test convert_arguments(Lines, myvector, mynestedvector) == (Point2f.(1:10, 11:20),)

    @test isequal(
        convert_arguments(Lines, [1, missing, 2]),
        (Point2f[(1, 1), (2, NaN), (3, 2)],)
    )

    @test isequal(
        convert_arguments(Lines, [Point(1, 2), missing, Point(3, 4)]),
        (Point2f[(1.0, 2.0), (NaN, NaN), (3.0, 4.0)],)
    )
end

@testset "categorical colors" begin
    @test categorical_colors([to_color(:red)], 1) == [to_color(:red)]
    @test categorical_colors([:red], 1) == [to_color(:red)]
    @test_throws ErrorException categorical_colors([to_color(:red)], 2)
    @test categorical_colors(:darktest, 1) == to_color.(Makie.PlotUtils.palette(:darktest))[1:1]
    @test_throws ErrorException to_colormap(:viridis, 10) # deprecated
    @test categorical_colors(:darktest, 1) == to_color.(Makie.PlotUtils.palette(:darktest))[1:1]
    @test categorical_colors(:viridis, 10) == to_colormap(:viridis)[1:10]
    # TODO why don't they exactly match?
    @test categorical_colors(:Set1, 9) ≈ to_colormap(:Set1)

    @test_throws ArgumentError Makie.categorical_colors(:PuRd, 20) # not enough categories
end

@testset "resample colormap" begin
    cs = Makie.resample_cmap(:viridis, 10; alpha=LinRange(0, 1, 10))
    @test Colors.alpha.(cs) == Float32.(LinRange(0, 1, 10))
    cs = Makie.resample_cmap(:viridis, 2; alpha=0.5)
    @test all(x-> x == 0.5, Colors.alpha.(cs))
    @test Colors.color.(cs) == Colors.color.(Makie.resample(to_colormap(:viridis), 2))
    cs = Makie.resample_cmap(:Set1, 100)
    @test all(x-> x == 1.0, Colors.alpha.(cs))
    @test Colors.color.(cs) == Colors.color.(Makie.resample(to_colormap(:Set1), 100))
    cs = Makie.resample_cmap(:Set1, 10; alpha=(0, 1))
    @test Colors.alpha.(cs) == Float32.(LinRange(0, 1, 10))
end

@testset "colors" begin
    @test to_color(["red", "green"]) isa Vector{RGBAf}
    @test to_color(["red", "green"]) == [to_color("red"), to_color("green")]
end


@testset "heatmap from three vectors" begin
    x = [2, 1, 2]
    y = [2, 3, 3]
    z = [1, 2, 3]
    xx, yy, zz = convert_arguments(Heatmap, x, y, z)
    @test xx == Float32[0.5, 1.5, 2.5]
    @test yy == Float32[1.5, 2.5, 3.5]
    @test isequal(zz, [NaN 2; 1 3])

    x = [1, 2]
    @test_throws ErrorException convert_arguments(Heatmap, x, y, z)
    x = copy(y)
    @test_throws ErrorException convert_arguments(Heatmap, x, y, z)
    x = [NaN, 1, 2]
    @test_throws ErrorException convert_arguments(Heatmap, x, y, z)
end

@testset "to_colormap" begin
    @test to_colormap([HSL(0, 10, 20)]) isa Vector{RGBAf}
    @test to_colormap([:red, :green]) isa Vector{RGBAf}
    @test to_colormap([(:red, 0.1), (:green, 0.2)]) isa Vector{RGBAf}
    @test to_colormap((:viridis, 0.1)) isa Vector{RGBAf}
    @test to_colormap(Reverse(:viridis)) isa Vector{RGBAf}
    @test to_colormap(:cividis) isa Vector{RGBAf}
    @test to_colormap(cgrad(:cividis, 8, categorical=true)) isa Vector{RGBAf}
    @test to_colormap(cgrad(:cividis, 8)) isa Vector{RGBAf}
    @test to_colormap(cgrad(:cividis)) isa Vector{RGBAf}
    @test alpha(to_colormap(cgrad(:cividis, 8; alpha=0.5))[1]) == 0.5
    @test alpha(to_colormap(cgrad(:cividis, 8; alpha=0.5, categorical=true))[1]) == 0.5


    @inferred to_colormap([HSL(0, 10, 20)])
    @inferred to_colormap([:red, :green])
    @inferred to_colormap([(:red, 0.1), (:green, 0.2)])
    @inferred to_colormap((:viridis, 0.1))
    @inferred to_colormap(Reverse(:viridis))
    @inferred to_colormap(:cividis)
    @inferred to_colormap(cgrad(:cividis, 8, categorical=true))
    @inferred to_colormap(cgrad(:cividis, 8))
    @inferred to_colormap(cgrad(:cividis))
    @inferred to_colormap(cgrad(:cividis, 8; alpha=0.5))
    @inferred to_colormap(cgrad(:cividis, 8; alpha=0.5, categorical=true))
end


@testset "empty poly" begin
    # Geometry Primitive
    f, ax, pl = poly(Rect2f[]);
    pl[1] = [Rect2f(0, 0, 1, 1)];
    @test pl.plots[1][1][] == [GeometryBasics.triangle_mesh(Rect2f(0, 0, 1, 1))]

    # Empty Polygon
    f, ax, pl = poly(Polygon(Point2f[]));
    pl[1] = Polygon(Point2f[(1,0), (1,1), (0,1)]);
    @test pl.plots[1][1][] == GeometryBasics.triangle_mesh(pl[1][])

    f, ax, pl = poly(Polygon[]);
    pl[1] = [Polygon(Point2f[(1,0), (1,1), (0,1)])];
    @test pl.plots[1][1][] == GeometryBasics.triangle_mesh.(pl[1][])

    # PointBased inputs
    f, ax, pl = poly(Point2f[])
    points = decompose(Point2f, Circle(Point2f(0),1))
    pl[1] = points
    @test pl.plots[1][1][] == Makie.poly_convert(points)

    f, ax, pl = poly(Vector{Point2f}[])
    pl[1] = [points]
    @test pl.plots[1][1][] == Makie.poly_convert(points)
end

@testset "Triplot" begin
    xs = rand(Float32, 10)
    ys = rand(Float32, 10)
    ps = Point2f.(xs, ys)

    @test convert_arguments(Triplot, xs, ys)[1] == ps
    @test convert_arguments(Triplot, ps)[1] == ps

    f, a, p = triplot(xs, ys)
    tri = p.plots[1][1][]
    @test tri.points ≈ ps
end

@testset "Voronoiplot" begin
    xs = rand(Float32, 10)
    ys = rand(Float32, 10)
    ps = Point2f.(xs, ys)

    @test convert_arguments(Voronoiplot, xs, ys)[1] == ps
    @test convert_arguments(Voronoiplot, ps)[1] == ps

    f, a, p = voronoiplot(xs, ys)
    tess = p.plots[1][1][]
    @test Point2f[tess.generators[i] for i in 1:10] ≈ ps

    # Heatmap style signatures
    xs = rand(Float32, 10)
    ys = rand(Float32, 10)
    zs = rand(Float32, 10, 10)

    @test convert_arguments(Voronoiplot, zs)[1] == Point3f.(1:10, (1:10)', zs)[:]
    @test convert_arguments(Voronoiplot, xs, ys, zs)[1] == Point3f.(xs, ys', zs)[:]

    # color sorting
    zs = [exp(-(x-y)^2) for x in LinRange(-1, 1, 10), y in LinRange(-1, 1, 10)]
    fig, ax, sc = voronoiplot(1:10, 1:10, zs, markersize = 10, strokewidth = 3)
    ps = [Point2f(x, y) for x in 1:10 for y in 1:10]
    vorn = Makie.DelTri.voronoi(Makie.DelTri.triangulate(ps))
    sc2 = voronoiplot!(vorn, color = zs, markersize = 10, strokewidth = 3)

    for plot in (sc.plots[1], sc2)
        polycols = plot.plots[1].color[]
        polys = plot.plots[1][1][]
        cs = zeros(10, 10)
        for (p, c) in zip(polys, polycols)
            # calculate center of poly, round to indices
            i, j = clamp.(round.(Int, sum(first.(p.exterior)) / length(p.exterior)), 1, 10)
            cs[i, j] = c
        end

        @test isapprox(cs, zs, rtol = 1e-6)
    end
end