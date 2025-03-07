################################################################################
#                             Lines, LineSegments                              #
################################################################################

function draw_atomic(scene::Scene, screen::Screen, @nospecialize(primitive::Union{Lines, LineSegments}))
    fields = @get_attribute(primitive, (color, linewidth, linestyle))
    linestyle = Makie.convert_attribute(linestyle, Makie.key"linestyle"())
    ctx = screen.context
    model = primitive[:model][]
    positions = primitive[1][]

    isempty(positions) && return

    # workaround for a LineSegments object created from a GLNormalMesh
    # the input argument is a view of points using faces, which results in
    # a vector of tuples of two points. we convert those to a list of points
    # so they don't trip up the rest of the pipeline
    # TODO this shouldn't be necessary anymore!
    if positions isa SubArray{<:Point3, 1, P, <:Tuple{Array{<:AbstractFace}}} where P
        positions = let
            pos = Point3f[]
            for tup in positions
                push!(pos, tup[1])
                push!(pos, tup[2])
            end
            pos
        end
    end

    space = to_value(get(primitive, :space, :data))
    projected_positions = project_position.(Ref(scene), (Makie.transform_func(primitive),), Ref(space), positions, Ref(model))

    color = to_color(primitive.calculated_colors[])

    # color is now a color or an array of colors
    # if it's an array of colors, each segment must be stroked separately

    # The linestyle can be set globally, as we do here.
    # However, there is a discrepancy between Makie
    # and Cairo when it comes to linestyles.
    # For Makie, the linestyle array is cumulative,
    # and defines the "absolute" endpoints of segments.
    # However, for Cairo, each value provides the length of
    # alternate "on" and "off" portions of the stroke.
    # Therefore, we take the diff of the given linestyle,
    # to convert the "absolute" coordinates into "relative" ones.
    if !isnothing(linestyle) && !(linewidth isa AbstractArray)
        pattern = diff(Float64.(linestyle)) .* linewidth
        isodd(length(pattern)) && push!(pattern, 0)
        Cairo.set_dash(ctx, pattern)
    end

    if primitive isa Lines && primitive.input_args[1][] isa BezierPath
        return draw_bezierpath_lines(ctx, primitive.input_args[1][], scene, color, space, model, linewidth)
    end

    if color isa AbstractArray || linewidth isa AbstractArray
        # stroke each segment separately, this means disjointed segments with probably
        # wonky dash patterns if segments are short

        # Butted segments look the best for varying colors, at least when connection angles are small.
        # While round style has nicer sharp joins, it looks bad with alpha colors (double paint) and
        # also messes with dash patterns (they are too long because of the caps)
        Cairo.set_line_cap(ctx, Cairo.CAIRO_LINE_CAP_BUTT)
        draw_multi(
            primitive, ctx,
            projected_positions,
            color, linewidth,
            isnothing(linestyle) ? nothing : diff(Float64.(linestyle))
        )
    else
        # stroke the whole line at once if it has only one color
        # this allows correct linestyles and line joins as well and will be the
        # most common case
        Cairo.set_line_width(ctx, linewidth)
        Cairo.set_source_rgba(ctx, red(color), green(color), blue(color), alpha(color))
        draw_single(primitive, ctx, projected_positions)
    end
    nothing
end

function draw_bezierpath_lines(ctx, bezierpath::BezierPath, scene, color, space, model, linewidth)
    for c in bezierpath.commands
        proj_comm = project_command(c, scene, space, model)
        path_command(ctx, proj_comm)
    end
    Cairo.set_source_rgba(ctx, rgbatuple(color)...)
    Cairo.set_line_width(ctx, linewidth)
    Cairo.stroke(ctx)
    return
end

function project_command(m::MoveTo, scene, space, model)
    MoveTo(project_position(scene, space, m.p, model))
end

function project_command(l::LineTo, scene, space, model)
    LineTo(project_position(scene, space, l.p, model))
end

function project_command(c::CurveTo, scene, space, model)
    CurveTo(
        project_position(scene, space, c.c1, model),
        project_position(scene, space, c.c2, model),
        project_position(scene, space, c.p, model),
    )
end

project_command(c::ClosePath, scene, space, model) = c

function draw_single(primitive::Lines, ctx, positions)
    n = length(positions)
    @inbounds for i in 1:n
        p = positions[i]
        # only take action for non-NaNs
        if !isnan(p)
            # new line segment at beginning or if previously NaN
            if i == 1 || isnan(positions[i-1])
                Cairo.move_to(ctx, p...)
            else
                Cairo.line_to(ctx, p...)
                # complete line segment at end or if next point is NaN
                if i == n || isnan(positions[i+1])
                    Cairo.stroke(ctx)
                end
            end
        end
    end
    # force clearing of path in case of skipped NaN
    Cairo.new_path(ctx)
end

function draw_single(primitive::LineSegments, ctx, positions)

    @assert iseven(length(positions))

    @inbounds for i in 1:2:length(positions)-1
        p1 = positions[i]
        p2 = positions[i+1]

        if isnan(p1) || isnan(p2)
            continue
        else
            Cairo.move_to(ctx, p1...)
            Cairo.line_to(ctx, p2...)
            Cairo.stroke(ctx)
        end
    end
    # force clearing of path in case of skipped NaN
    Cairo.new_path(ctx)
end

# if linewidth is not an array
function draw_multi(primitive, ctx, positions, colors::AbstractArray, linewidth, dash)
    draw_multi(primitive, ctx, positions, colors, [linewidth for c in colors], dash)
end

# if color is not an array
function draw_multi(primitive, ctx, positions, color, linewidths::AbstractArray, dash)
    draw_multi(primitive, ctx, positions, [color for l in linewidths], linewidths, dash)
end

function draw_multi(primitive::LineSegments, ctx, positions, colors::AbstractArray, linewidths::AbstractArray, dash)
    @assert iseven(length(positions))
    @assert length(positions) == length(colors)
    @assert length(linewidths) == length(colors)

    for i in 1:2:length(positions)
        if isnan(positions[i+1]) || isnan(positions[i])
            continue
        end
        if linewidths[i] != linewidths[i+1]
            error("Cairo doesn't support two different line widths ($(linewidths[i]) and $(linewidths[i+1])) at the endpoints of a line.")
        end
        Cairo.move_to(ctx, positions[i]...)
        Cairo.line_to(ctx, positions[i+1]...)
        Cairo.set_line_width(ctx, linewidths[i])

        !isnothing(dash) && Cairo.set_dash(ctx, dash .* linewidths[i])
        c1 = colors[i]
        c2 = colors[i+1]
        # we can avoid the more expensive gradient if the colors are the same
        # this happens if one color was given for each segment
        if c1 == c2
            Cairo.set_source_rgba(ctx, red(c1), green(c1), blue(c1), alpha(c1))
            Cairo.stroke(ctx)
        else
            pat = Cairo.pattern_create_linear(positions[i]..., positions[i+1]...)
            Cairo.pattern_add_color_stop_rgba(pat, 0, red(c1), green(c1), blue(c1), alpha(c1))
            Cairo.pattern_add_color_stop_rgba(pat, 1, red(c2), green(c2), blue(c2), alpha(c2))
            Cairo.set_source(ctx, pat)
            Cairo.stroke(ctx)
            Cairo.destroy(pat)
        end
    end
end

function draw_multi(primitive::Lines, ctx, positions, colors::AbstractArray, linewidths::AbstractArray, dash)
    @assert length(positions) == length(colors)
    @assert length(linewidths) == length(colors)

    prev_color = colors[begin]
    prev_linewidth = linewidths[begin]
    prev_position = positions[begin]
    prev_nan = isnan(prev_position)
    prev_continued = false

    if !prev_nan
        # first is not nan, move_to
        Cairo.move_to(ctx, positions[begin]...)
    else
        # first is nan, do nothing
    end

    for i in eachindex(positions)[2:end]
        this_position = positions[i]
        this_color = colors[i]
        this_nan = isnan(this_position)
        this_linewidth = linewidths[i]
        if this_nan
            # this is nan
            if prev_continued
                # and this is prev_continued, so set source and stroke to finish previous line
                Cairo.set_line_width(ctx, this_linewidth)
                !isnothing(dash) && Cairo.set_dash(ctx, dash .* this_linewidth)
                Cairo.set_source_rgba(ctx, red(prev_color), green(prev_color), blue(prev_color), alpha(prev_color))
                Cairo.stroke(ctx)
            else
                # but this is not prev_continued, so do nothing
            end
        end
        if prev_nan
            # previous was nan
            if !this_nan
                # but this is not nan, so move to this position
                Cairo.move_to(ctx, this_position...)
            else
                # and this is also nan, do nothing
            end
        else
            if this_color == prev_color
                # this color is like the previous
                if !this_nan
                    # and this is not nan, so line_to and set prev_continued
                    this_linewidth != prev_linewidth && error("Encountered two different linewidth values $prev_linewidth and $this_linewidth in `lines` at index $(i-1). Different linewidths in one line are only permitted in CairoMakie when separated by a NaN point.")
                    Cairo.line_to(ctx, this_position...)
                    prev_continued = true
                    
                    if i == lastindex(positions)
                        # this is the last element so stroke this
                        Cairo.set_line_width(ctx, this_linewidth)
                        !isnothing(dash) && Cairo.set_dash(ctx, dash .* this_linewidth)
                        Cairo.set_source_rgba(ctx, red(this_color), green(this_color), blue(this_color), alpha(this_color))
                        Cairo.stroke(ctx)
                    end
                else
                    # but this is nan, so do nothing
                end
            else
                prev_continued = false
                if !this_nan
                    this_linewidth != prev_linewidth && error("Encountered two different linewidth values $prev_linewidth and $this_linewidth in `lines` at index $(i-1). Different linewidths in one line are only permitted in CairoMakie when separated by a NaN point.")
                    # this is not nan
                    # and this color is different than the previous, so move_to prev and line_to this
                    # create gradient pattern and stroke
                    Cairo.move_to(ctx, prev_position...)
                    Cairo.line_to(ctx, this_position...)
                    !isnothing(dash) && Cairo.set_dash(ctx, dash .* this_linewidth)
                    Cairo.set_line_width(ctx, this_linewidth)

                    pat = Cairo.pattern_create_linear(prev_position..., this_position...)
                    Cairo.pattern_add_color_stop_rgba(pat, 0, red(prev_color), green(prev_color), blue(prev_color), alpha(prev_color))
                    Cairo.pattern_add_color_stop_rgba(pat, 1, red(this_color), green(this_color), blue(this_color), alpha(this_color))
                    Cairo.set_source(ctx, pat)
                    Cairo.stroke(ctx)
                    Cairo.destroy(pat)

                    Cairo.move_to(ctx, this_position...)
                else
                    # this is nan, do nothing
                end
            end
        end
        prev_nan = this_nan
        prev_color = this_color
        prev_linewidth = linewidths[i]
        prev_position = this_position
    end
end

################################################################################
#                                   Scatter                                    #
################################################################################

function draw_atomic(scene::Scene, screen::Screen, @nospecialize(primitive::Scatter))
    fields = @get_attribute(primitive, (markersize, strokecolor, strokewidth, marker, marker_offset, rotations))
    @get_attribute(primitive, (transform_marker,))

    ctx = screen.context
    model = primitive.model[]
    positions = primitive[1][]
    isempty(positions) && return
    size_model = transform_marker ? model : Mat4f(I)

    font = to_font(to_value(get(primitive, :font, Makie.defaultfont())))

    colors = to_color(primitive.calculated_colors[])

    markerspace = to_value(get(primitive, :markerspace, :pixel))
    space = to_value(get(primitive, :space, :data))

    transfunc = Makie.transform_func(primitive)

    marker_conv = _marker_convert(marker)

    draw_atomic_scatter(scene, ctx, transfunc, colors, markersize, strokecolor, strokewidth, marker_conv, marker_offset, rotations, model, positions, size_model, font, markerspace, space)
end

# an array of markers is converted to string by itself, which is inconvenient for the iteration logic
_marker_convert(markers::AbstractArray) = map(m -> convert_attribute(m, key"marker"(), key"scatter"()), markers)
_marker_convert(marker) = convert_attribute(marker, key"marker"(), key"scatter"())
# image arrays need to be converted as a whole
_marker_convert(marker::AbstractMatrix{<:Colorant}) = [ convert_attribute(marker, key"marker"(), key"scatter"()) ]

function draw_atomic_scatter(scene, ctx, transfunc, colors, markersize, strokecolor, strokewidth, marker, marker_offset, rotations, model, positions, size_model, font, markerspace, space)
    broadcast_foreach(positions, colors, markersize, strokecolor,
            strokewidth, marker, marker_offset, remove_billboard(rotations)) do point, col,
            markersize, strokecolor, strokewidth, m, mo, rotation

        scale = project_scale(scene, markerspace, markersize, size_model)
        offset = project_scale(scene, markerspace, mo, size_model)

        pos = project_position(scene, transfunc, space, point, model)
        isnan(pos) && return

        Cairo.set_source_rgba(ctx, rgbatuple(col)...)

        Cairo.save(ctx)
        marker_converted = Makie.to_spritemarker(m)
        # Setting a markersize of 0.0 somehow seems to break Cairos global state?
        # At least it stops drawing any marker afterwards
        # TODO, maybe there's something wrong somewhere else?
        if !(norm(scale) ≈ 0.0)
            if marker_converted isa Char
                draw_marker(ctx, marker_converted, best_font(m, font), pos, scale, strokecolor, strokewidth, offset, rotation)
            else
                draw_marker(ctx, marker_converted, pos, scale, strokecolor, strokewidth, offset, rotation)
            end
        end
        Cairo.restore(ctx)
    end
    return
end

function draw_marker(ctx, marker::Char, font, pos, scale, strokecolor, strokewidth, marker_offset, rotation)
    # Marker offset is meant to be relative to the
    # bottom left corner of the box centered at
    # `pos` with sides defined by `scale`, but
    # this does not take the character's dimensions
    # into account.
    # Here, we reposition the marker offset to be
    # relative to the center of the char.
    marker_offset = marker_offset .+ scale ./ 2

    cairoface = set_ft_font(ctx, font)

    charextent = Makie.FreeTypeAbstraction.get_extent(font, marker)
    inkbb = Makie.FreeTypeAbstraction.inkboundingbox(charextent)

    # scale normalized bbox by font size
    inkbb_scaled = Rect2f(origin(inkbb) .* scale, widths(inkbb) .* scale)

    # flip y for the centering shift of the character because in Cairo y goes down
    centering_offset = Vec2f(1, -1) .* (-origin(inkbb_scaled) .- 0.5f0 .* widths(inkbb_scaled))
    # this is the origin where we actually have to place the glyph so it can be centered
    charorigin = pos .+ Vec2f(marker_offset[1], -marker_offset[2])
    old_matrix = get_font_matrix(ctx)
    set_font_matrix(ctx, scale_matrix(scale...))

    # First, we translate to the point where the
    # marker is supposed to go.
    Cairo.translate(ctx, charorigin[1], charorigin[2])
    # Then, we rotate the context by the
    # appropriate amount,
    Cairo.rotate(ctx, to_2d_rotation(rotation))
    # and apply a centering offset to account for
    # the fact that text is shown from the (relative)
    # bottom left corner.
    Cairo.translate(ctx, centering_offset[1], centering_offset[2])

    Cairo.move_to(ctx, 0, 0)
    Cairo.text_path(ctx, string(marker))
    Cairo.fill_preserve(ctx)
    # stroke
    Cairo.set_line_width(ctx, strokewidth)
    Cairo.set_source_rgba(ctx, rgbatuple(strokecolor)...)
    Cairo.stroke(ctx)

    # if we use set_ft_font we should destroy the pointer it returns
    cairo_font_face_destroy(cairoface)

    set_font_matrix(ctx, old_matrix)
end

function draw_marker(ctx, ::Type{<: Circle}, pos, scale, strokecolor, strokewidth, marker_offset, rotation)
    marker_offset = marker_offset + scale ./ 2
    pos += Point2f(marker_offset[1], -marker_offset[2])

    if scale[1] != scale[2]
        old_matrix = Cairo.get_matrix(ctx)
        Cairo.scale(ctx, scale[1], scale[2])
        Cairo.translate(ctx, pos[1]/scale[1], pos[2]/scale[2])
        Cairo.arc(ctx, 0, 0, 0.5, 0, 2*pi)
    else
        Cairo.arc(ctx, pos[1], pos[2], scale[1]/2, 0, 2*pi)
    end

    Cairo.fill_preserve(ctx)

    Cairo.set_line_width(ctx, Float64(strokewidth))

    sc = to_color(strokecolor)
    Cairo.set_source_rgba(ctx, rgbatuple(sc)...)
    Cairo.stroke(ctx)
    scale[1] != scale[2] && Cairo.set_matrix(ctx, old_matrix)
    nothing
end

function draw_marker(ctx, ::Type{<: Rect}, pos, scale, strokecolor, strokewidth, marker_offset, rotation)
    s2 = Point2((scale .* (1, -1))...)
    pos = pos .+ Point2f(marker_offset[1], -marker_offset[2])
    Cairo.rotate(ctx, to_2d_rotation(rotation))
    Cairo.rectangle(ctx, pos[1], pos[2], s2...)
    Cairo.fill_preserve(ctx)
    Cairo.set_line_width(ctx, Float64(strokewidth))
    sc = to_color(strokecolor)
    Cairo.set_source_rgba(ctx, rgbatuple(sc)...)
    Cairo.stroke(ctx)
end

function draw_marker(ctx, beziermarker::BezierPath, pos, scale, strokecolor, strokewidth, marker_offset, rotation)
    Cairo.save(ctx)
    Cairo.translate(ctx, pos[1], pos[2])
    Cairo.rotate(ctx, to_2d_rotation(rotation))
    Cairo.scale(ctx, scale[1], -scale[2]) # flip y for cairo
    draw_path(ctx, beziermarker)
    Cairo.fill_preserve(ctx)
    sc = to_color(strokecolor)
    Cairo.set_source_rgba(ctx, rgbatuple(sc)...)
    Cairo.set_line_width(ctx, Float64(strokewidth))
    Cairo.stroke(ctx)
    Cairo.restore(ctx)
end

draw_path(ctx, bp::BezierPath) = foreach(x -> path_command(ctx, x), bp.commands)
path_command(ctx, c::MoveTo) = Cairo.move_to(ctx, c.p...)
path_command(ctx, c::LineTo) = Cairo.line_to(ctx, c.p...)
path_command(ctx, c::CurveTo) = Cairo.curve_to(ctx, c.c1..., c.c2..., c.p...)
path_command(ctx, ::ClosePath) = Cairo.close_path(ctx)
function path_command(ctx, c::EllipticalArc)
    Cairo.save(ctx)
    Cairo.translate(ctx, c.c...)
    Cairo.rotate(ctx, c.angle)
    Cairo.scale(ctx, 1, c.r2 / c.r1)
    if c.a2 > c.a1
        Cairo.arc(ctx, 0, 0, c.r1, c.a1, c.a2)
    else
        Cairo.arc_negative(ctx, 0, 0, c.r1, c.a1, c.a2)
    end
    Cairo.restore(ctx)
end


function draw_marker(ctx, marker::Matrix{T}, pos, scale,
        strokecolor #= unused =#, strokewidth #= unused =#,
        marker_offset, rotation) where T<:Colorant

    # convert marker to Cairo compatible image data
    marker = permutedims(marker, (2,1))
    marker_surf = to_cairo_image(marker)

    w, h = size(marker)

    Cairo.translate(ctx,
                    scale[1]/2 + pos[1] + marker_offset[1],
                    scale[2]/2 + pos[2] + marker_offset[2])
    Cairo.rotate(ctx, to_2d_rotation(rotation))
    Cairo.scale(ctx, scale[1] / w, scale[2] / h)
    Cairo.set_source_surface(ctx, marker_surf, -w/2, -h/2)
    Cairo.paint(ctx)
end


################################################################################
#                                     Text                                     #
################################################################################

function p3_to_p2(p::Point3{T}) where T
    if p[3] == 0 || isnan(p[3])
        Point2{T}(p[Vec(1,2)]...)
    else
        error("Can't reduce Point3 to Point2 with nonzero third component $(p[3]).")
    end
end

function draw_atomic(scene::Scene, screen::Screen, @nospecialize(primitive::Text{<:Tuple{<:Union{AbstractArray{<:Makie.GlyphCollection}, Makie.GlyphCollection}}}))
    ctx = screen.context
    @get_attribute(primitive, (rotation, model, space, markerspace, offset))
    position = primitive.position[]
    # use cached glyph info
    glyph_collection = to_value(primitive[1])

    draw_glyph_collection(
        scene, ctx, position, glyph_collection, remove_billboard(rotation),
        model, space, markerspace, offset, primitive.transformation
    )

    nothing
end


function draw_glyph_collection(
        scene, ctx, positions, glyph_collections::AbstractArray, rotation,
        model::Mat, space, markerspace, offset, transformation
    )

    # TODO: why is the Ref around model necessary? doesn't broadcast_foreach handle staticarrays matrices?
    broadcast_foreach(positions, glyph_collections, rotation, Ref(model), space,
        markerspace, offset) do pos, glayout, ro, mo, sp, msp, off

        draw_glyph_collection(scene, ctx, pos, glayout, ro, mo, sp, msp, off, transformation)
    end
end

_deref(x) = x
_deref(x::Ref) = x[]

function draw_glyph_collection(scene, ctx, position, glyph_collection, rotation, _model, space, markerspace, offsets, transformation)

    glyphs = glyph_collection.glyphs
    glyphoffsets = glyph_collection.origins
    fonts = glyph_collection.fonts
    rotations = glyph_collection.rotations
    scales = glyph_collection.scales
    colors = glyph_collection.colors
    strokewidths = glyph_collection.strokewidths
    strokecolors = glyph_collection.strokecolors

    model = _deref(_model)
    model33 = model[Vec(1, 2, 3), Vec(1, 2, 3)]
    id = Mat4f(I)

    glyph_pos = let
        transform_func = transformation.transform_func[]
        p = Makie.apply_transform(transform_func, position, space)

        Makie.clip_to_space(scene.camera, markerspace) *
        Makie.space_to_clip(scene.camera, space) *
        model * to_ndim(Point4f, to_ndim(Point3f, p, 0), 1)
    end

    Cairo.save(ctx)

    broadcast_foreach(glyphs, glyphoffsets, fonts, rotations, scales, colors, strokewidths, strokecolors, offsets) do glyph,
        glyphoffset, font, rotation, scale, color, strokewidth, strokecolor, offset

        cairoface = set_ft_font(ctx, font)
        old_matrix = get_font_matrix(ctx)

        p3_offset = to_ndim(Point3f, offset, 0)

        # Not renderable by font (e.g. '\n')
        # TODO, filter out \n in GlyphCollection, and render unrenderables as box
        glyph == 0 && return

        Cairo.save(ctx)
        Cairo.set_source_rgba(ctx, rgbatuple(color)...)

        # offsets and scale apply in markerspace
        gp3 = glyph_pos[Vec(1, 2, 3)] ./ glyph_pos[4] .+ model33 * (glyphoffset .+ p3_offset)

        scale3 = scale isa Number ? Point3f(scale, scale, 0) : to_ndim(Point3f, scale, 0)

        # the CairoMatrix is found by transforming the right and up vector
        # of the character into screen space and then subtracting the projected
        # origin. The resulting vectors give the directions in which the character
        # needs to be stretched in order to match the 3D projection

        xvec = rotation * (scale3[1] * Point3f(1, 0, 0))
        yvec = rotation * (scale3[2] * Point3f(0, -1, 0))

        glyphpos = _project_position(scene, markerspace, gp3, id, true)
        xproj = _project_position(scene, markerspace, gp3 + model33 * xvec, id, true)
        yproj = _project_position(scene, markerspace, gp3 + model33 * yvec, id, true)

        xdiff = xproj - glyphpos
        ydiff = yproj - glyphpos

        mat = Cairo.CairoMatrix(
            xdiff[1], xdiff[2],
            ydiff[1], ydiff[2],
            0, 0,
        )

        Cairo.save(ctx)
        set_font_matrix(ctx, mat)
        show_glyph(ctx, glyph, glyphpos...)
        Cairo.restore(ctx)

        if strokewidth > 0 && strokecolor != RGBAf(0, 0, 0, 0)
            Cairo.save(ctx)
            Cairo.move_to(ctx, glyphpos...)
            set_font_matrix(ctx, mat)
            glyph_path(ctx, glyph, glyphpos...)
            Cairo.set_source_rgba(ctx, rgbatuple(strokecolor)...)
            Cairo.set_line_width(ctx, strokewidth)
            Cairo.stroke(ctx)
            Cairo.restore(ctx)
        end
        Cairo.restore(ctx)

        cairo_font_face_destroy(cairoface)
        set_font_matrix(ctx, old_matrix)
    end

    Cairo.restore(ctx)
    return
end

################################################################################
#                                Heatmap, Image                                #
################################################################################

"""
    regularly_spaced_array_to_range(arr)
If possible, converts `arr` to a range.
If not, returns array unchanged.
"""
function regularly_spaced_array_to_range(arr)
    diffs = unique!(sort!(diff(arr)))
    step = sum(diffs) ./ length(diffs)
    if all(x-> x ≈ step, diffs)
        m, M = extrema(arr)
        if step < zero(step)
            m, M = M, m
        end
        # don't use stop=M, since that may not include M
        return range(m; step=step, length=length(arr))
    else
        return arr
    end
end

regularly_spaced_array_to_range(arr::AbstractRange) = arr

function premultiplied_rgba(a::AbstractArray{<:ColorAlpha})
    map(premultiplied_rgba, a)
end
premultiplied_rgba(a::AbstractArray{<:Color}) = RGBA.(a)

premultiplied_rgba(r::RGBA) = RGBA(r.r * r.alpha, r.g * r.alpha, r.b * r.alpha, r.alpha)
premultiplied_rgba(c::Colorant) = premultiplied_rgba(RGBA(c))

function draw_atomic(scene::Scene, screen::Screen, @nospecialize(primitive::Union{Heatmap, Image}))
    ctx = screen.context
    image = primitive[3][]
    xs, ys = primitive[1][], primitive[2][]
    if !(xs isa AbstractVector)
        l, r = extrema(xs)
        N = size(image, 1)
        xs = range(l, r, length = N+1)
    else
        xs = regularly_spaced_array_to_range(xs)
    end
    if !(ys isa AbstractVector)
        l, r = extrema(ys)
        N = size(image, 2)
        ys = range(l, r, length = N+1)
    else
        ys = regularly_spaced_array_to_range(ys)
    end
    model = primitive.model[]::Mat4f
    interpolate = to_value(primitive.interpolate)

    # Debug attribute we can set to disable fastpath
    # probably shouldn't really be part of the interface
    fast_path = to_value(get(primitive, :fast_path, true))
    disable_fast_path = !fast_path
    # Vector backends don't support FILTER_NEAREST for interp == false, so in that case we also need to draw rects
    is_vector = is_vector_backend(ctx)
    t = Makie.transform_func(primitive)
    identity_transform = (t === identity || t isa Tuple && all(x-> x === identity, t)) && (abs(model[1, 2]) < 1e-15)
    regular_grid = xs isa AbstractRange && ys isa AbstractRange
    xy_aligned = let 
        # Only allow scaling and translation
        pv = scene.camera.projectionview[]
        M = Mat4f(
            pv[1, 1], 0.0,      0.0,      0.0,
            0.0,      pv[2, 2], 0.0,      0.0,
            0.0,      0.0,      pv[3, 3], 0.0,
            pv[1, 4], pv[2, 4], pv[3, 4], 1.0
        )
        pv ≈ M
    end

    if interpolate
        if !regular_grid
            error("$(typeof(primitive).parameters[1]) with interpolate = true with a non-regular grid is not supported right now.")
        end
        if !identity_transform
            error("$(typeof(primitive).parameters[1]) with interpolate = true with a non-identity transform is not supported right now.")
        end
    end

    imsize = ((first(xs), last(xs)), (first(ys), last(ys)))
    # find projected image corners
    # this already takes care of flipping the image to correct cairo orientation
    space = to_value(get(primitive, :space, :data))
    xy = project_position(scene, space, Point2f(first.(imsize)), model)
    xymax = project_position(scene, space, Point2f(last.(imsize)), model)
    w, h = xymax .- xy

    can_use_fast_path = !(is_vector && !interpolate) && regular_grid && identity_transform && 
        (interpolate || xy_aligned)
    use_fast_path = can_use_fast_path && !disable_fast_path

    if use_fast_path
        s = to_cairo_image(to_color(primitive.calculated_colors[]))

        weird_cairo_limit = (2^15) - 23
        if s.width > weird_cairo_limit || s.height > weird_cairo_limit
            error("Cairo stops rendering images bigger than $(weird_cairo_limit), which is likely a bug in Cairo. Please resample your image/heatmap with e.g. `ImageTransformations.imresize`")
        end
        Cairo.rectangle(ctx, xy..., w, h)
        Cairo.save(ctx)
        Cairo.translate(ctx, xy...)
        Cairo.scale(ctx, w / s.width, h / s.height)
        Cairo.set_source_surface(ctx, s, 0, 0)
        p = Cairo.get_source(ctx)
        # this is needed to avoid blurry edges
        Cairo.pattern_set_extend(p, Cairo.EXTEND_PAD)
        filt = interpolate ? Cairo.FILTER_BILINEAR : Cairo.FILTER_NEAREST
        Cairo.pattern_set_filter(p, filt)
        Cairo.fill(ctx)
        Cairo.restore(ctx)
    else
        # find projected image corners
        # this already takes care of flipping the image to correct cairo orientation
        space = to_value(get(primitive, :space, :data))
        xys = project_position.(scene, (Makie.transform_func(primitive),), space, [Point2f(x, y) for x in xs, y in ys], (model,))
        colors = to_color(primitive.calculated_colors[])

        # Note: xs and ys should have size ni+1, nj+1
        ni, nj = size(image)
        if ni + 1 != length(xs) || nj + 1 != length(ys)
            error("Error in conversion pipeline. xs and ys should have size ni+1, nj+1. Found: xs: $(length(xs)), ys: $(length(ys)), ni: $(ni), nj: $(nj)")
        end
        _draw_rect_heatmap(ctx, xys, ni, nj, colors)
    end
end

function _draw_rect_heatmap(ctx, xys, ni, nj, colors)
    @inbounds for i in 1:ni, j in 1:nj
        p1 = xys[i, j]
        p2 = xys[i+1, j]
        p3 = xys[i+1, j+1]
        p4 = xys[i, j+1]

        # Rectangles and polygons that are directly adjacent usually show
        # white lines between them due to anti aliasing. To avoid this we
        # increase their size slightly.

        if alpha(colors[i, j]) == 1
            # sign.(p - center) gives the direction in which we need to
            # extend the polygon. (Which may change due to rotations in the
            # model matrix.) (i!=1) etc is used to avoid increasing the
            # outer extent of the heatmap.
            center = 0.25f0 * (p1 + p2 + p3 + p4)
            p1 += sign.(p1 - center) .* Point2f(0.5f0 * (i!=1),  0.5f0 * (j!=1))
            p2 += sign.(p2 - center) .* Point2f(0.5f0 * (i!=ni), 0.5f0 * (j!=1))
            p3 += sign.(p3 - center) .* Point2f(0.5f0 * (i!=ni), 0.5f0 * (j!=nj))
            p4 += sign.(p4 - center) .* Point2f(0.5f0 * (i!=1),  0.5f0 * (j!=nj))
        end

        Cairo.set_line_width(ctx, 0)
        Cairo.move_to(ctx, p1[1], p1[2])
        Cairo.line_to(ctx, p2[1], p2[2])
        Cairo.line_to(ctx, p3[1], p3[2])
        Cairo.line_to(ctx, p4[1], p4[2])
        Cairo.close_path(ctx)
        Cairo.set_source_rgba(ctx, rgbatuple(colors[i, j])...)
        Cairo.fill(ctx)
    end
end


################################################################################
#                                     Mesh                                     #
################################################################################


function draw_atomic(scene::Scene, screen::Screen, @nospecialize(primitive::Makie.Mesh))
    mesh = primitive[1][]
    if Makie.cameracontrols(scene) isa Union{Camera2D, Makie.PixelCamera, Makie.EmptyCamera}
        draw_mesh2D(scene, screen, primitive, mesh)
    else
        if !haskey(primitive, :faceculling)
            primitive[:faceculling] = Observable(-10)
        end
        draw_mesh3D(scene, screen, primitive, mesh)
    end
    return nothing
end

function draw_mesh2D(scene, screen, @nospecialize(plot), @nospecialize(mesh))
    vs =  decompose(Point2f, mesh)::Vector{Point2f}
    fs = decompose(GLTriangleFace, mesh)::Vector{GLTriangleFace}
    uv = decompose_uv(mesh)::Union{Nothing, Vector{Vec2f}}
    model = plot.model[]::Mat4f
    color = hasproperty(mesh, :color) ? to_color(mesh.color) : plot.calculated_colors[]
    cols = per_face_colors(color, nothing, fs, nothing, uv)
    space = to_value(get(plot, :space, :data))::Symbol
    transform_func = Makie.transform_func(plot)
    return draw_mesh2D(scene, screen, cols, space, transform_func, vs, fs, model)
end

function draw_mesh2D(scene, screen, per_face_cols, space::Symbol, transform_func,
        vs::Vector{Point2f}, fs::Vector{GLTriangleFace}, model::Mat4f)

    ctx = screen.context
    # Priorize colors of the mesh if present
    # This is a hack, which needs cleaning up in the Mesh plot type!

    for (f, (c1, c2, c3)) in zip(fs, per_face_cols)
        pattern = Cairo.CairoPatternMesh()
        t1, t2, t3 =  project_position.(scene, (transform_func,), space, vs[f], (model,)) #triangle points
        Cairo.mesh_pattern_begin_patch(pattern)

        Cairo.mesh_pattern_move_to(pattern, t1...)
        Cairo.mesh_pattern_line_to(pattern, t2...)
        Cairo.mesh_pattern_line_to(pattern, t3...)

        mesh_pattern_set_corner_color(pattern, 0, c1)
        mesh_pattern_set_corner_color(pattern, 1, c2)
        mesh_pattern_set_corner_color(pattern, 2, c3)

        Cairo.mesh_pattern_end_patch(pattern)
        Cairo.set_source(ctx, pattern)
        Cairo.close_path(ctx)
        Cairo.paint(ctx)
        Cairo.destroy(pattern)
    end
    return nothing
end

function average_z(positions, face)
    vs = positions[face]
    sum(v -> v[3], vs) / length(vs)
end

nan2zero(x) = !isnan(x) * x


function draw_mesh3D(scene, screen, attributes, mesh; pos = Vec4f(0), scale = 1f0)
    # Priorize colors of the mesh if present
    @get_attribute(attributes, (color,))

    matcap = to_value(get(attributes, :matcap, nothing))

    meshpoints = decompose(Point3f, mesh)::Vector{Point3f}
    meshfaces = decompose(GLTriangleFace, mesh)::Vector{GLTriangleFace}
    meshnormals = decompose_normals(mesh)::Vector{Vec3f}
    meshuvs = texturecoordinates(mesh)::Union{Nothing, Vector{Vec2f}}

    color = hasproperty(mesh, :color) ? mesh.color : to_value(attributes.calculated_colors)

    per_face_col = per_face_colors(color, matcap, meshfaces, meshnormals, meshuvs)

    @get_attribute(attributes, (shading, diffuse,
        specular, shininess, faceculling))

    model = attributes.model[]::Mat4f
    space = to_value(get(attributes, :space, :data))::Symbol
    func = Makie.transform_func(attributes)
    draw_mesh3D(
        scene, screen, space, func, meshpoints, meshfaces, meshnormals, per_face_col, pos, scale,
        model, shading::Bool, diffuse::Vec3f,
        specular::Vec3f, shininess::Float32, faceculling::Int
    )
end

function draw_mesh3D(
        scene, screen, space, transform_func, meshpoints, meshfaces, meshnormals, per_face_col, pos, scale,
        model, shading, diffuse,
        specular, shininess, faceculling
    )
    ctx = screen.context
    view = ifelse(is_data_space(space), scene.camera.view[], Mat4f(I))
    projection = Makie.space_to_clip(scene.camera, space, false)
    i = Vec(1, 2, 3)
    normalmatrix = transpose(inv(view[i, i] * model[i, i]))

    # Mesh data
    # transform to view/camera space

    # pass transform_func as argument to function, so that we get a function barrier
    # and have `transform_func` be fully typed inside closure
    vs = broadcast(meshpoints, (transform_func,)) do v, f
        # Should v get a nan2zero?
        v = Makie.apply_transform(f, v, space)
        p4d = to_ndim(Vec4f, scale .* to_ndim(Vec3f, v, 0f0), 1f0)
        view * (model * p4d .+ to_ndim(Vec4f, pos, 0f0))
    end

    ns = map(n -> normalize(normalmatrix * n), meshnormals)
    # Liight math happens in view/camera space
    pointlight = Makie.get_point_light(scene)
    lightposition = if !isnothing(pointlight)
        pointlight.position[]
    else
        Vec3f(0)
    end

    ambientlight = Makie.get_ambient_light(scene)
    ambient = if !isnothing(ambientlight)
        c = ambientlight.color[]
        Vec3f(c.r, c.g, c.b)
    else
        Vec3f(0)
    end

    lightpos = (view * to_ndim(Vec4f, lightposition, 1.0))[Vec(1, 2, 3)]

    # Camera to screen space
    ts = map(vs) do v
        clip = projection * v
        @inbounds begin
            p = (clip ./ clip[4])[Vec(1, 2)]
            p_yflip = Vec2f(p[1], -p[2])
            p_0_to_1 = (p_yflip .+ 1f0) ./ 2f0
        end
        p = p_0_to_1 .* scene.camera.resolution[]
        return Vec3f(p[1], p[2], clip[3])
    end

    # Approximate zorder
    average_zs = map(f -> average_z(ts, f), meshfaces)
    zorder = sortperm(average_zs)

    # Face culling
    zorder = filter(i -> any(last.(ns[meshfaces[i]]) .> faceculling), zorder)

    draw_pattern(ctx, zorder, shading, meshfaces, ts, per_face_col, ns, vs, lightpos, shininess, diffuse, ambient, specular)
    return
end

function _calculate_shaded_vertexcolors(N, v, c, lightpos, ambient, diffuse, specular, shininess)
    L = normalize(lightpos .- v[Vec(1,2,3)])
    diff_coeff = max(dot(L, N), 0f0)
    H = normalize(L + normalize(-v[Vec(1, 2, 3)]))
    spec_coeff = max(dot(H, N), 0f0)^shininess
    c = RGBAf(c)
    # if this is one expression it introduces allocations??
    new_c_part1 = (ambient .+ diff_coeff .* diffuse) .* Vec3f(c.r, c.g, c.b) #.+
    new_c = new_c_part1 .+ specular * spec_coeff
    RGBAf(new_c..., c.alpha)
end

function draw_pattern(ctx, zorder, shading, meshfaces, ts, per_face_col, ns, vs, lightpos, shininess, diffuse, ambient, specular)
    for k in reverse(zorder)
        pattern = Cairo.CairoPatternMesh()

        f = meshfaces[k]
        # avoid SizedVector through Face indexing
        t1 = ts[f[1]]
        t2 = ts[f[2]]
        t3 = ts[f[3]]

        facecolors = per_face_col[k]
        # light calculation
        if shading
            c1, c2, c3 = Base.Cartesian.@ntuple 3 i -> begin
                # these face index expressions currently allocate for SizedVectors
                # if done like `ns[f]`
                N = ns[f[i]]
                v = vs[f[i]]
                c = facecolors[i]
                _calculate_shaded_vertexcolors(N, v, c, lightpos, ambient, diffuse, specular, shininess)
            end
        else
            c1, c2, c3 = facecolors
        end

        # debug normal coloring
        # n1, n2, n3 = Vec3f(0.5) .+ 0.5ns[f]
        # c1 = RGB(n1...)
        # c2 = RGB(n2...)
        # c3 = RGB(n3...)

        Cairo.mesh_pattern_begin_patch(pattern)

        Cairo.mesh_pattern_move_to(pattern, t1[1], t1[2])
        Cairo.mesh_pattern_line_to(pattern, t2[1], t2[2])
        Cairo.mesh_pattern_line_to(pattern, t3[1], t3[2])

        mesh_pattern_set_corner_color(pattern, 0, c1)
        mesh_pattern_set_corner_color(pattern, 1, c2)
        mesh_pattern_set_corner_color(pattern, 2, c3)

        Cairo.mesh_pattern_end_patch(pattern)
        Cairo.set_source(ctx, pattern)
        Cairo.close_path(ctx)
        Cairo.paint(ctx)
        Cairo.destroy(pattern)
    end

end

################################################################################
#                                   Surface                                    #
################################################################################


function draw_atomic(scene::Scene, screen::Screen, @nospecialize(primitive::Makie.Surface))
    # Pretend the surface plot is a mesh plot and plot that instead
    mesh = surface2mesh(primitive[1][], primitive[2][], primitive[3][])
    old = primitive[:color]
    if old[] === nothing
        primitive[:color] = primitive[3]
    end
    if !haskey(primitive, :faceculling)
        primitive[:faceculling] = Observable(-10)
    end
    draw_mesh3D(scene, screen, primitive, mesh)
    primitive[:color] = old
    return nothing
end

function surface2mesh(xs, ys, zs::AbstractMatrix)
    ps = Makie.matrix_grid(p-> nan2zero.(p), xs, ys, zs)
    rect = Tesselation(Rect2f(0, 0, 1, 1), size(zs))
    faces = decompose(QuadFace{Int}, rect)
    uv = map(x-> Vec2f(1f0 - x[2], 1f0 - x[1]), decompose_uv(rect))
    uvm = GeometryBasics.Mesh(GeometryBasics.meta(ps; uv=uv), faces)
    return GeometryBasics.normal_mesh(uvm)
end

################################################################################
#                                 MeshScatter                                  #
################################################################################


function draw_atomic(scene::Scene, screen::Screen, @nospecialize(primitive::Makie.MeshScatter))
    @get_attribute(primitive, (model, marker, markersize, rotations))

    m = convert_attribute(marker, key"marker"(), key"meshscatter"())
    pos = primitive[1][]
    # For correct z-ordering we need to be in view/camera or screen space
    model = copy(model)
    view = scene.camera.view[]

    zorder = sortperm(pos, by = p -> begin
        p4d = to_ndim(Vec4f, to_ndim(Vec3f, p, 0f0), 1f0)
        cam_pos = view * model * p4d
        cam_pos[3] / cam_pos[4]
    end, rev=false)

    color = to_color(primitive.calculated_colors[])
    submesh = Attributes(
        model=model,
        calculated_colors = color,
        shading=primitive.shading, diffuse=primitive.diffuse,
        specular=primitive.specular, shininess=primitive.shininess,
        faceculling=get(primitive, :faceculling, -10),
        transformation=Makie.transformation(primitive)

    )

    if !(rotations isa Vector)
        R = Makie.rotationmatrix4(to_rotation(rotations))
        submesh[:model] = model * R
    end
    scales = primitive[:markersize][]
    for i in zorder
        p = pos[i]
        if color isa AbstractVector
            submesh[:calculated_colors] = color[i]
        end
        if rotations isa Vector
            R = Makie.rotationmatrix4(to_rotation(rotations[i]))
            submesh[:model] = model * R
        end
        scale = markersize isa Vector ? markersize[i] : markersize

        draw_mesh3D(
            scene, screen, submesh, m, pos = p,
            scale = scale isa Real ? Vec3f(scale) : to_ndim(Vec3f, scale, 1f0)
        )
    end

    return nothing
end
