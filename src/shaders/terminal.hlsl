cbuffer GridConfig : register(b0)
{
    uint2 cell_size;
    uint col_count;
    uint row_count;
    float scrollbar_y;
    float scrollbar_height;
    float scrollbar_x;
    float scrollbar_width;
    uint background;
    uint foreground;
    uint cursor_color_packed;
    float opacity;
    uint cursor_x;
    uint cursor_y;
    float cursor_alpha;
    uint cursor_style;
    uint tab_count;
    uint active_tab_index;
    int tab_hover_index;
    uint tab_position;
    uint viewport_height;
    uint3 padding;
}

struct Cell
{
    uint glyph_index;
    uint bg;
    uint fg;
};
StructuredBuffer<Cell> cells : register(t0);
Texture2D<float4> glyph_texture : register(t1);

float4 VertexMain(uint id : SV_VERTEXID) : SV_POSITION
{
    return float4(
        2.0 * (float(id & 1) - 0.5),
        -(float(id >> 1) - 0.5) * 2.0,
        0, 1
    );
}

float4 UnpackRgba(uint packed)
{
    float4 unpacked;
    unpacked.r = (float)((packed >> 24) & 0xFF) / 255.0f;
    unpacked.g = (float)((packed >> 16) & 0xFF) / 255.0f;
    unpacked.b = (float)((packed >> 8) & 0xFF) / 255.0f;
    unpacked.a = (float)(packed & 0xFF) / 255.0f;
    return unpacked;
}

float4 PixelMain(float4 sv_pos : SV_POSITION) : SV_TARGET {
    // 1. Resolve the actual background color from your config
    float4 config_bg = UnpackRgba(background);

    // 2. Calculate dynamic background
    float2 pos = sv_pos.xy / (cell_size * float2(col_count, row_count));
    float3 dynamic_bg = config_bg.rgb + float3(
        lerp(-0.005, 0.005, pos.x),
        lerp(-0.01, 0.005, pos.y),
        lerp(-0.005, 0.01, (pos.x + pos.y) * 0.5)
    );

    float noise = frac(sin(dot(sv_pos.xy, float2(12.9898, 78.233))) * 43758.5453);
    noise = (noise - 0.5) / 255.0;
    dynamic_bg += noise;

    // 3. Tabs (Bookmarks) rendering
    bool tabs_on_left = (tab_position == 0 || tab_position == 2);
    bool tabs_on_bottom = (tab_position == 2 || tab_position == 3);
    float tab_area_y = tabs_on_bottom ? max(0.0, (float)viewport_height - 30.0) : 0.0;

    if (sv_pos.y >= tab_area_y && sv_pos.y < tab_area_y + 30.0) {
        float tab_w = 16.0;
        float spacing = 8.0;
        float total_tabs = tab_count + 1.0;
        float tab_area_width = tab_w * total_tabs + spacing * (total_tabs - 1.0);
        float tab_start_x = tabs_on_left ? 8.0 : scrollbar_x - tab_area_width - 8.0;
        float tab_local_y = tabs_on_bottom ? ((float)viewport_height - sv_pos.y) : (sv_pos.y - tab_area_y);
        
        if (sv_pos.x >= tab_start_x && sv_pos.x < scrollbar_x - 8.0) {
            float local_x = sv_pos.x - tab_start_x;
            uint tab_idx = (uint)(local_x / (tab_w + spacing));
            float x_in_tab = fmod(local_x, (tab_w + spacing));
            
            if (tab_idx < (uint)total_tabs && x_in_tab < tab_w) {
                bool is_plus = (tab_idx == (uint)tab_count);
                bool active = !is_plus && (tab_idx == active_tab_index);
                float tab_height = active ? 24.0 : 16.0;
                
                if (tab_local_y < tab_height) {
                    float3 tab_color = active ? float3(1.0, 0.72, 0.0) : lerp(dynamic_bg, float3(1,1,1), 0.2);
                    if (tab_idx == (uint)tab_hover_index) {
                        tab_color = lerp(tab_color, float3(1,1,1), 0.1);
                    }
                    
                    if (is_plus) {
                        float2 center = float2(tab_w / 2.0, 16.0 / 2.0);
                        float2 p = float2(x_in_tab, tab_local_y) - center;
                        if ((abs(p.x) < 1.0 && abs(p.y) < 4.0) || (abs(p.y) < 1.0 && abs(p.x) < 4.0)) {
                            tab_color = float3(1,1,1);
                        }
                    }
                    
                    return float4(tab_color * opacity, opacity);
                }
            }
        }
    }

    // 4. Scrollbar area
    if (scrollbar_width > 0 && sv_pos.x >= scrollbar_x) {
        float3 color = dynamic_bg;
        float alpha = opacity;

        if (sv_pos.y >= scrollbar_y && sv_pos.y < scrollbar_y + scrollbar_height)
        {
            color = lerp(color, float3(1.0, 1.0, 1.0), 0.05);
        }

        return float4(color * alpha, alpha);
    }

    // 5. Cell grid logic
    uint col = sv_pos.x / cell_size.x;
    uint row = sv_pos.y / cell_size.y;
    if (col >= col_count || row >= row_count) return float4(dynamic_bg * opacity, opacity);
    uint cell_index = row * col_count + col;

    Cell cell = cells[cell_index];
    float4 bg = UnpackRgba(cell.bg);
    float4 fg = UnpackRgba(cell.fg);

    uint texture_width, texture_height;
    glyph_texture.GetDimensions(texture_width, texture_height);
    uint cells_per_row = texture_width / cell_size.x;

    uint2 glyph_cell_pos = uint2(
        cell.glyph_index % cells_per_row,
        cell.glyph_index / cells_per_row
    );
    uint2 cell_pixel = uint2(sv_pos.xy) % cell_size;
    uint2 texture_coord = glyph_cell_pos * cell_size + cell_pixel;
    float4 glyph_texel = glyph_texture.Load(int3(texture_coord, 0));

    // 6. Blending logic
    float3 blended_bg = lerp(dynamic_bg, bg.rgb, bg.a);
    float3 color = lerp(blended_bg, fg.rgb, fg.a * glyph_texel.a);
    float alpha = lerp(opacity, 1.0, fg.a * glyph_texel.a);

    // 7. Cursor rendering
    if (col == cursor_x && row == cursor_y) {
        float4 cursor_color = UnpackRgba(cursor_color_packed);
        bool in_cursor = false;
        if (cursor_style == 0) { // Block
            in_cursor = true;
        } else if (cursor_style == 1) { // Pipe
            if (cell_pixel.x < 2) {
                in_cursor = true;
            }
        }

        if (in_cursor) {
            if (cursor_style == 0) {
                float3 inv_bg = cursor_color.rgb;
                float3 inv_fg = config_bg.rgb;

                float3 block_bg = lerp(blended_bg, inv_bg, cursor_alpha);
                float3 block_fg = lerp(fg.rgb, inv_fg, cursor_alpha);

                color = lerp(block_bg, block_fg, fg.a * glyph_texel.a);
            } else {
                color = lerp(color, cursor_color.rgb, cursor_alpha);
            }
        }
    }

    return float4(color * alpha, alpha);
}


