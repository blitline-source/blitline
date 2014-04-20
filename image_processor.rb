require 'blitline/job/http_client'

module Blitline
  class ImageProcessor
    require 'RMagick'
    require 'tempfile'

    extend Blitline::ExternalTools

    VINTAGE_WHITE_CENTRAL = "http://s3.amazonaws.com/img.blitline/grad_center_light_indexed.png"
    VINTAGE_VIGNETTE = "http://s3.amazonaws.com/img.blitline/grad_vignette_index.png"
    LOMO_BURN = "http://s3.amazonaws.com/img.blitline/filters/lomo.png"

    def initialize(image, image_cache = nil, uploader = nil)
      @image = image
      @image_cache = image_cache
      @uploader = uploader
    end

    def crop_from_source(params)
      @image = Magick::Image.read(params['src']).first
      x1 = interize(params["x1"], 0)
      x2 = interize(params["x2"], 10)
      y1 = interize(params["y1"], 0)
      y2 = interize(params["y2"], 10)
      return @image.crop(x1,y1,(x2-x1), (y2-y1))
    end

    def adaptive_blur(params)
      radius = floaterize(params['radius'], 0.0)
      sigma = floaterize(params['sigma'], 1.0)
      return @image.adaptive_blur(radius, sigma)
    end

    def adaptive_sharpen(params)
      radius = floaterize(params['radius'], 0.0)
      sigma = floaterize(params['sigma'], 1.0)
      return @image.adaptive_sharpen(radius, sigma)
    end

    def add_profile(params)
      src = params['src']
      file_path = nil
      begin
        file_path = Blitline::HttpClient.download_file(src)
        @image = @image.add_profile(file_path)
      ensure
        FileUtils.rm file_path if file_path && File.exists?(file_path)
      end

      return @image
    end

    def annotate(params)
      draw = Magick::Draw.new()

      width = interize(params['width'], 0)
      height = interize(params['height'], 0)
      x = interize(params['x'], 0)
      y = interize(params['y'], 0)
      font_weight = weight_from_name(params['weight'], Magick::BoldWeight)
      text = params['text'] || "please add text param"
      color = params['color'] || '#ffffff'
      font_family = params['font_family'] || 'Helvetica'
      point_size = floaterize(params['point_size'], 32)
      stroke = params['stroke'] || 'transparent'
      style = style_from_name(params['style'], Magick::NormalStyle)
      gravity = params['gravity'] || 'CenterGravity'
      gravity = gravity_from_name(gravity)
      kerning = params['kerning'] ? floaterize(params['kerning'],1) : nil

      if params['dropshadow_color']
        dropshadow_color = params['dropshadow_color']
        dropshadow_offset = interize(params['dropshadow_offset'], 2)
        layer = Magick::Image.new(@image.columns, @image.rows) { self.background_color = 'transparent'}
        draw.annotate(layer, width, height, x+dropshadow_offset, y+dropshadow_offset, text){
                  self.font_family = font_family
                  self.fill = dropshadow_color
                  self.font_style = style
                  self.stroke = stroke
                  self.kerning = kerning if kerning
                  self.pointsize = point_size
                  self.font_weight = font_weight
                  self.gravity = gravity
              }
        layer = layer.blur_channel(0,1, Magick::AllChannels)

        draw.annotate(layer, width, height, x, y, text){
            self.font_family = font_family
            self.fill = color
            self.font_style = style
            self.stroke = stroke
            self.kerning = kerning if kerning
            self.pointsize = point_size
            self.font_weight = font_weight
            self.gravity = gravity
        }
        @image = @image.composite(layer, Magick::CenterGravity, Magick::OverCompositeOp)

      else
        draw.annotate(@image, width, height, x, y, text){
            self.font_family = font_family
            self.fill = color
            self.font_style = style
            self.stroke = stroke
            self.kerning = kerning if kerning
            self.pointsize = point_size
            self.font_weight = font_weight
            self.gravity = gravity
        }
      end

      return @image
    end

    def auto_level(params)
      return @image.auto_level_channel(Magick::AllChannels)
    end

    def auto_gamma(params)
      return @image.auto_gamma_channel(Magick::AllChannels)
    end

    def auto_enhance(params)
      f = Tempfile.open('blitline_enhance_in')
      begin
        temp_filepath = f.path + ".png"
      ensure
         f.close!
      end

      f = Tempfile.open('blitline_enhance_out')
      begin
        temp_output_filepath = f.path + ".png"
      ensure
         f.close!
      end

      begin
        @image.write(temp_filepath)
        Blitline::ExternalTools.auto_enhance(temp_filepath, temp_output_filepath)
        @return_image = Magick::Image.read(temp_output_filepath).first
      rescue => ex
        raise "Failed to auto_enhance #{ex.message}"
      ensure
         FileUtils.rm temp_filepath if File.exists? temp_filepath
         FileUtils.rm temp_output_filepath if File.exists? temp_output_filepath
      end

      return @return_image
    end

    def blue_shift(params)
      factor = floaterize(params['factor'], 1.5)
      return @image.blue_shift(factor)
    end

    def no_op(params)
      return @image
    end

    def append(params)
      other_images = params['other_images']
      vertical = params['vertical'] || false
      image_list = Magick::ImageList.new
      image_list.push(@image)
      other_images.split(",").each do |url|
        image_list.push(Magick::Image.read(url).first)
      end
      return image_list.append(vertical)
    end

    def blur(params)
      radius = floaterize(params['radius'], 0.0)
      sigma = floaterize(params['sigma'], 1.0)
      return @image.blur_image(radius, sigma)
    end

    def background_color(params)
      return pad({'color' => params['color'], 'size' => 0})
    end

    def crop_from_source(params)
      src = params["url"]
      scale = floaterize(params['scale'], 1.0)
      target_width = interize(params["target_width"], 10)
      target_width = target_width
      target_height = interize(params["target_height"], 10)
      target_width = target_width
      x1 = interize(params["x1"], 0)
      x1 = x1 * scale
      y1 = interize(params["y1"], 0)
      y1 = y1 * scale
      x2 = interize(params["x2"], 10)
      x2 = x2 * scale
      y2 = interize(params["y2"], 10)
      y2 = y2 * scale
      width = x2 - x1
      height = y2 - y1

      if (x1 == -1 or y1 == -1)
        raise "Imagga couldn't determine a smart crop."
      end
      simple_image_loader = Blitline::ImageLoader.new(nil, nil, nil, nil, nil)
      @image = simple_image_loader.try_load_from_local_download(src)
      @image.crop!(x1, y1, width.abs, height.abs, true)
      @image.resize!(target_width, target_height)
      return @image
    end

    def composite(params)
      if params['src'].is_a?(Hash)
          simple_image_loader = Blitline::ImageLoader.new(nil, nil, nil, nil, nil)
          src = simple_image_loader.load_complex_source(params, @uploader)
      else
        if params['src'][0,1]=="&"
          image_key = params['src'].reverse.chop.reverse
          BlitlineLogger.log("Looking for image_key #{image_key}")
          src = @image_cache[image_key]
          raise "Image reference '#{image_key}'' not found. Preprocessing probably failed." unless src
        else
          src = Magick::Image.read(params['src']).first
        end
      end

      if params['as_mask'].to_s.downcase == "true"
        @image.matte = true
        src.matte = false
      end

      if params['scale_to_match'].to_s.downcase == "true"
        src = src.scale(@image.columns, @image.rows)
      end

      x = interize(params['x'], 0)
      y = interize(params['y'], 0)
      gravity = params['gravity'] ? gravity_from_name(params['gravity']) : nil

      if params['composite_op']
        composite_op = Magick.const_get(params['composite_op'])
      else
        composite_op = Magick::OverCompositeOp
      end

      if gravity
        final_image = @image.composite(src, gravity, composite_op)
      else
        final_image = @image.composite(src, x, y, composite_op)
      end

      return final_image
    end


    def contrast(params)
      sharpen = params['sharpen'] || false
      return @image.contrast(sharpen)
    end

    def contrast_stretch_channel(params)
      black_point = floaterize(params['black_point'], 1.0)
      white_point = floaterize(params['white_point'], 1.0) if params['white_point']

      if white_point
        return @image.contrast_stretch_channel(black_point, white_point)
      end

      return @image.contrast_stretch_channel(black_point)
    end

    def convert_command(params)
      f = Tempfile.open('blitline_convert_in')
      begin
        temp_filepath = f.path + ".png"
      ensure
         f.close!
      end

      f = Tempfile.open('blitline_convert_out')
      begin
        temp_output_filepath = f.path + ".png"
      ensure
         f.close!
      end

      begin
        @image.write(temp_filepath)
        Blitline::ExternalTools.run_convert_command(params, temp_filepath, temp_output_filepath)
        @return_image = Magick::Image.read(temp_output_filepath).first
      ensure
         FileUtils.rm temp_filepath if File.exists? temp_filepath
         FileUtils.rm temp_output_filepath if File.exists? temp_output_filepath
      end

      return @return_image
    end

    def convert_to_dpi(params)
      density = interize(params['dpi'], 72)
      dpi_image = Magick::Image.new(@image.columns, @image.rows) {
        self.density = "#{density}x#{density}"
        self.background_color = "none"
      }
      new_image = dpi_image.composite(@image, Magick::CenterGravity, Magick::OverCompositeOp)
      return new_image
    end


    def crop(params)
      x = interize(params['x'])
      y = interize(params['y'])
      width = interize(params['width'])
      height = interize(params['height'])
      gravity = gravity_from_name(params['gravity'])

      only_shrink_larger = params['only_shrink_larger'].nil? ? "false" : params['only_shrink_larger'].to_s.downcase
      if only_shrink_larger=="true"
        return @image if already_below_constraints?(@image, width, height)
      end

      preserve_aspect_if_smaller = params['preserve_aspect_if_smaller'].nil? ? "false" : params['preserve_aspect_if_smaller'].to_s.downcase
      if preserve_aspect_if_smaller=="true"
        #already_below_constraints?
        if either_below_constraints?(@image, width, height)
          new_width = @image.columns
          new_height = @image.rows

          if @image.rows > @image.columns
            new_width = @image.columns
            new_height = new_width.to_f * (height.to_f / width.to_f)
          else
            new_height = @image.rows
            new_width = new_height.to_f * (width.to_f / height.to_f)
          end
          width = new_width
          height = new_height
        end
      end

      if params['gravity']
        return @image.crop(gravity, x.to_i, y.to_i, width.to_i, height.to_i, true)
      end

      return @image.crop(x, y, width, height, true)
    end

    def crop_to_square(params)
      gravity = gravity_from_name(params['gravity'])
      x = interize(params['x'])
      y = interize(params['y'])
      width = @image.columns
      height = @image.rows

      target_length = (width > height) ? height : width;

      return @image.crop(gravity, x, y, target_length, target_length, true)
    end

    def delete_profile(params)
      profile_name = params['name']
      if profile_name && profile_name[0,4]=="http"
        begin
          file_path = Blitline::HttpClient.download_file(profile_name)
          @image = @image.delete_profile(file_path)
        ensure
          FileUtils.rm file_path if file_path && File.exists?(file_path)
        end
      else
        @image = @image.delete_profile(profile_name)
      end

      return @image
    end

    def density(params)
      dpi = params['dpi'].to_s
      @image.density = dpi
      return @image
    end

    def despeckle(params)
      return @image.despeckle
    end

    def deskew(params)
      threshold = floaterize(params['threshold'], 0.4)
      return @image.deskew(threshold)
    end

    def enhance(params)
      return @image.enhance
    end

    def equalize(params)
      return @image.equalize
    end

    def gamma_channel(params)
      gamma = floaterize(params['gamma'], 0.8) # usually 0.8 to 2.3
      return @image.gamma_channel(gamma)
    end

    def gray_colorspace(params)
      return @image.quantize(65535, Magick::GRAYColorspace, Magick::NoDitherMethod)
    end

    def interlace(params)
      interlace_type = interlace_from_name(params['type'])
      @image.interlace = interlace_type
      puts interlace_type.inspect
      return @image
    end

    def ellipse(params)
      opacity = floaterize(params['stroke_opacity'], 1.0)
      stroke_width = interize(params['stroke_width'], 0)
      color = params['color'] || "#ffffff"
      fill_color = params['fill_color'] || color
      fill_opacity = floaterize(params['fill_opacity'], 1.0) 

      origin_x = params['origin_x']
      origin_y = params['origin_y']

      ellipse_width = params['ellipse_width']
      ellipse_height = params['ellipse_height']

      raise "Ellipse method must have origin_x,origin_y,width,height values" if origin_x.nil? || origin_y.nil? || ellipse_width.nil? || ellipse_height.nil?

      draw = Magick::Draw.new
      draw.fill_color(fill_color)
      draw.fill_opacity(fill_opacity)
      if stroke_width > 0
        draw.stroke_width(stroke_width)
        draw.stroke(color)
        draw.stroke_opacity(opacity)
      end

      draw.ellipse(origin_x, origin_y, ellipse_width, ellipse_height, 0, 360)
      new_image = @image.copy
      draw.draw(new_image)
      return new_image
    end

    def rectangle(params)
      is_rounded_rectangle = false
      stroke_opacity = floaterize(params['stroke_opacity'], 1.0)
      opacity = params['opacity']
      stroke_width = interize(params['stroke_width'], 0)
      color = params['color'] || "#ffffff"
      fill_color = params['fill_color'] || color
      fill_opacity = floaterize(params['fill_opacity'], 1.0) 
      cw = params['cw']
      ch = params['ch']

      if cw && ch 
        is_rounded_rectangle = true
        cw = interize(cw, 1)
        ch = interize(ch, 1)
      end

      start_x = params['x']
      start_y = params['y']

      end_x = params['x1']
      end_y = params['y1']

      raise "Rectangle method must have x,y,x1,y1 values" if start_x.nil? || start_y.nil? || end_x.nil? || end_y.nil?

      draw = Magick::Draw.new
      if stroke_width > 0
        draw.stroke_opacity(stroke_opacity)
        draw.stroke_width(stroke_width)
        draw.stroke(color)
      end
      draw.fill_color(fill_color)
      draw.fill_opacity(fill_opacity)

      if is_rounded_rectangle
        draw.roundrectangle(start_x,start_y,end_x,end_y, cw, ch)
      else
        draw.rectangle(start_x,start_y,end_x,end_y)
      end

      new_image = @image.copy
      draw.draw(new_image)
      return new_image

    end

    def line(params)
      opacity = floaterize(params['opacity'], 1.0)
      width = interize(params['width'], 1)
      color = params['color'] || "#ffffff"
      line_cap = params['line_cap'] || "butt"

      start_x = params['x']
      start_y = params['y']

      end_x = params['x1']
      end_y = params['y1']

      raise "Line method must have x,y,x1,y1 values" if start_x.nil? || start_y.nil? || end_x.nil? || end_y.nil?

      draw = Magick::Draw.new
      draw.fill(color)
      draw.stroke(color)
      draw.stroke_width(width)
      draw.opacity(opacity)
      draw.stroke_linecap(line_cap)

      draw.line(start_x,start_y,end_x,end_y)
      draw.draw(@image)
      return @image
    end

    def median_filter(params)
      radius = floaterize(params['radius'], 1.0)
      return @image.median_filter(radius)
    end

    def pad_resize_to_fit(params)
      color = params['color'] || "#ffffff"
      max_width = interize(params['width'])
      max_height = interize(params['height'])
      gravity = gravity_from_name(params['gravity'])

      src_width = @image.columns
      src_height = @image.rows

      min_ratio = [max_width.to_f/src_width.to_f, max_height.to_f/src_height.to_f].min
      target_width = src_width * min_ratio
      target_height = src_height * min_ratio

      background = Magick::Image.new(max_width, max_height) { self.background_color = color }
      if @image.colorspace == Magick::CMYKColorspace
        background.colorspace = Magick::CMYKColorspace
      end

      @image = @image.resize_to_fit(target_width, target_height)
      @image = background.composite(@image, gravity, Magick::OverCompositeOp)
      return @image
    end

    def pixelate(params)
      x = interize(params['x'], 0)
      y = interize(params['y'], 0)

      width = interize(params['width'], @image.columns)
      height = interize(params['height'], @image.rows)

      amount = floaterize(params['amount'], 10.0)

      if amount > 100.0 or amount <= 0.0
        amount = 10.0
      end

      coeff_1 = amount / 100
      coeff_2 = 1 / coeff_1

      area = @image.crop(x, y, width, height)
      puts "---", coeff_1, coeff_2
      area.scale!(coeff_1)
      area.scale!(coeff_2)
      area.crop!(x, y, width, height)

      return @image.composite(area, x, y, Magick::OverCompositeOp)
    end

    def modulate(params)
      brightness = floaterize(params['brightness'], 1.0)
      saturation = floaterize(params['saturation'], 1.0)
      hue = floaterize(params['hue'], 1.0)
      return @image.modulate(brightness, saturation, hue)
    end

    def normalize(params)
      return @image.normalize
    end

    def pad(params)
      size = interize(params['size'])
      gravity = gravity_from_name(params['gravity'])
      color =  params['color'] || "#ffffff"

      new_width = @image.columns
      new_height = @image.rows
      x = 0
      y = 0

      case gravity
        when Magick::SouthGravity
          new_height = new_height + size
        when Magick::NorthGravity
          new_height = new_height + size
          y = y - size
        when Magick::WestGravity
          new_width = new_width + size
          x = x - size
        when Magick::EastGravity
          new_width = new_width + size
        when Magick::CenterGravity
          new_height = new_height + (2 * size)
          new_width = new_width + (2 * size)
          x = x - size
          y = y - size
        else
          new_height = new_height + (2 * size)
          new_width = new_width + (2 * size)
          x = x - size
          y = y - size
      end

      new_image = @image.dup
      new_image.background_color = color
      return new_image.extent(new_width, new_height, x, y)
    end

    def photograph(params)
      angle = floaterize(params['angle'], -5.0)
      optional_arguments = params['optional_arguments']
      return @image.polaroid(angle)
    end

    def quantize(params)
        number_colors = interize(params['number_colors'], 8)
        dither = params['dither'].to_s == "true"
        colorspace = Blitline::ImageProcessor.colorspace_from_name(params['colorspace'])

        return @image.quantize(number_colors, colorspace, dither)
    end

    def resample(params)
      density = floaterize(params['density'], 72.0)
      return @image.resample(density)
    end

    def resize(params)
      width = interize(params['width'])
      height = interize(params['height'])
      if params['scale_factor']
        return @image.resize(floaterize(params['scale_factor'], 1.0))
      end
      return @image.resize(width, height)
    end

    def resize_to_fill(params)
      width = interize(params['width'])
      height = interize(params['height'])
      gravity =  params['gravity'] || 'CenterGravity'

      only_shrink_larger = params['only_shrink_larger'].nil? ? "false" : params['only_shrink_larger'].to_s.downcase
      if only_shrink_larger=="true"
        return @image if already_below_constraints?(@image, width, height)
      end

      return @image.resize_to_fill(width , height , gravity_from_name(gravity))
    end

    def resize_to_fit(params)
      width = interize(params['width'])
      height = interize(params['height'])

      only_shrink_larger = params['only_shrink_larger'].nil? ? "false" : params['only_shrink_larger'].to_s.downcase

      if only_shrink_larger=="true"
        return @image if already_below_constraints?(@image, width, height)
      end

      return @image.resize_to_fit(width , height)
    end

    def resize_to_fit_with_wrap(params)
      min_width = floaterize(params['width'], 1.0)
      min_height = floaterize(params['height'], 1.0)
      only_shrink_larger = params['only_shrink_larger'].nil? ? "false" : params['only_shrink_larger'].to_s.downcase

      width = @image.columns.to_f
      height = @image.rows.to_f

      aspect_src = width / height
      aspect_dst = min_width / min_height

      if aspect_src >= aspect_dst
        w = min_width * aspect_src / aspect_dst
        h = min_height
      else
        w = min_width
        h = min_height * aspect_dst / aspect_src
      end

      if only_shrink_larger=="true"
        return @image if already_below_constraints?(@image, min_width, min_height)
      end

      return @image.resize(w.to_i, h.to_i)
    end

    def rotate(params)
      amount = floaterize(params['amount'], 90)

      return @image.rotate(amount)
    end

    def scale(params)
      width = interize(params['width'])
      height = interize(params['height'])

      if params['scale_factor']
        return @image.scale(floaterize(params['scale_factor'], 0.0))
      end

      return @image.scale(width, height)
    end

    def script(params)
      files = params["files"] || ""
      bash_string = params["bash_string"] || ""
      executable = params["executeable"] || params["executable"] || ""

      if bash_string && bash_string.length > 0
        type = "text"
      elsif files.length > 0 && executable.length > 0
        type = "files"
      else
        raise "You must have either 'bash_string' or ('files' and 'executable') for script commands"
      end

      return_image = Blitline::ExternalTools.docker(@image, @uploader, type, files.split(","), executable, bash_string)
      return return_image
    end

    def sepia_tone(params)
      threshold = floaterize(params['threshold'], 0.80)
      return @image.sepiatone(Magick::QuantumRange * threshold)
    end

    def sharpen(params)
      radius = floaterize(params['radius'], 0.0)
      sigma = floaterize(params['sigma'], 1.0)
      return @image.sharpen(radius, sigma)
    end

    def sketch(params)
      radius = floaterize(params['radius'], 0.0)
      sigma = floaterize(params['sigma'], 1.0)
      angle = floaterize(params['angle'], 0.0)
      return @image.sketch(radius, sigma, angle)
    end

    def stegano(params)
      watermark_image_url = params['watermark_url']
      offset = interize(params["offset"],0)

      simple_image_loader = Blitline::ImageLoader.new(nil, nil, nil, nil, nil)
      watermark_image = simple_image_loader.try_load_from_local_download(watermark_image_url)

      return @image.stegano(watermark_image, offset)
    end

    def threshold(params)
      threshold_value = floaterize(params['threshold_value'], 0.5)
      return @image.threshold( Magick::QuantumRange * threshold_value);
    end

    def unsharp_mask(params)
      radius = floaterize(params['radius'], 0.0)
      sigma = floaterize(params['sigma'], 1.0)
      amount = floaterize(params['amount'], 1.0)
      threshold = floaterize(params['threshold'], 0.05)
      return @image.unsharp_mask(radius, sigma, amount, threshold)
    end

    def thumbnail(params)
      width = interize(params['width'])
      height = interize(params['height'])

      return @image.thumbnail(width, height)
    end

    def tile(params)
      src = nil
      if params['src'].is_a?(Hash)
          simple_image_loader = Blitline::ImageLoader.new(nil, nil, nil, nil, nil)
          src = simple_image_loader.load_complex_source(params, @uploader)
      else
        if params['src'][0,1]=="&"
          image_key = params['src'].reverse.chop.reverse
          BlitlineLogger.log("Looking for image_key #{image_key}")
          src = @image_cache[image_key]
          raise "Image reference '#{image_key}'' not found. Preprocessing probably failed." unless src
        else
          src = Magick::Image.read(params['src']).first
        end
      end

      raise "Failed to load 'src' for tile function." unless src

      new_image = @image.dup
      scale = floaterize(params['scale'],1)
      width = interize(params['width'],0)
      height = floaterize(params['height'],0)

      if width * height > 0
        src.resize!(width, height)
      else
        src.resize!(scale) unless scale == 1
      end

      y_step = ((@image.rows.to_f / src.rows.to_f) + 0.5).round
      x_step = ((@image.columns.to_f / src.columns.to_f) + 0.5).round

      y_step.times do |y|
        x_step.times do |x|
            new_image.composite!(src, Magick::NorthWestGravity, x*src.columns, y*src.rows, Magick::OverCompositeOp)
        end
      end

      return new_image
    end

    def trim(params)
      return @image.trim(true)
    end

    def vignette(params)
      color = params['color'] || '#000000'
      @image.background_color = color
      x = floaterize(params['x'], 10)
      y = floaterize(params['y'], 10)
      radius = floaterize(params['radius'], 0.0)
      sigma = floaterize(params['sigma'], 10.0)
      return @image.vignette(x, y, radius, sigma)
    end

    def watermark(params)
      text = params['text']
      gravity = params['gravity'] || 'CenterGravity'
      point_size = floaterize(params['point_size'], 94)
      font_family = params['font_family'] || 'Helvetica'
      opacity = floaterize(params['opacity'], 0.45)

      text_image = ::Magick::Image.new(@image.columns,@image.rows) {
       self.background_color = 'transparent'
      }
      processor = ::Blitline::ImageProcessor.new(text_image);
      text_image = processor.annotate({ 'color' => '#555555', 'width' => 0, 'height' => 0, 'x' => 1, 'y' => 1, 'text'=> text, 'gravity' => gravity, 'point_size' => point_size, 'font_family' => font_family})
      processor = ::Blitline::ImageProcessor.new(text_image);
      text_image = processor.annotate({ 'width' => 0, 'height' => 0, 'x' => 0, 'y' => 0, 'text'=> text, 'gravity' => gravity, 'point_size' => point_size, 'font_family' => font_family})

      return @image.dissolve(text_image, opacity, 0.75)
    end

    # --------------------------------------------------------------------------------------------------
    # Filters
    # --------------------------------------------------------------------------------------------------

    def celsius(params=nil)
      @image = @image.function_channel(Magick::PolynomialFunction, 0.454, -1.756, 2.133, 0.169, Magick::RedChannel)
      @image = @image.function_channel(Magick::PolynomialFunction, -0.311, 1.159, 0.106, Magick::GreenChannel)
      @image = @image.function_channel(Magick::PolynomialFunction, 1.108, -0.552, 0.402, Magick::BlueChannel)

      @image = level_out(@image, Magick::DefaultChannels, 0, 250, 0.94)
      @image = @image.gamma_channel(1.04, Magick::RedChannel)
      return @image
    end

=begin
    def meadowlark(params=nil)
      layer = Magick::Image.new(@image.columns, @image.rows) { self.background_color = '#FCF3D6' }
      @image.composite!(layer, 0, 0, Magick::MultiplyCompositeOp)
      @image = @image.modulate(1.0, 0.7, 1.0)
      @image = @image.gamma_channel(1.01, Magick::DefaultChannels)
      @image = level_out(@image, Magick::RedChannel, 27, 255)
      @image = @image.modulate(1.15, 1.0, 1.0)
      @image = @image.contrast(true)
      @image = @image.modulate(1.0, 0.83, 1.0)
      @image = level_in(@image, Magick::DefaultChannels, 0, 235, 0.92)
      lomo_burn = Magick::Image.read(LOMO_BURN).first
      lomo_burn.resize!(@image.columns , @image.rows)
      @image.composite!(lomo_burn, 0, 0, Magick::ColorBurnCompositeOp)
      @image.composite!(lomo_burn, 0, 0, Magick::MultiplyCompositeOp)

      return @image
    end
    def walden(params=nil) # Waldenlike
      @image = @image.modulate(1.26, 0.65, 1.0)
      @image = @image.contrast(true)
      return @image
    end
=end
    def lomo(params=nil)
      @image = @image.modulate(1.15, 1.0, 1.0)
      @image = @image.contrast(true)
      @image = @image.function_channel(Magick::PolynomialFunction, -1.855, 3.113, -0.257, 0)
      lomo_burn = Magick::Image.read(LOMO_BURN).first
      lomo_burn.resize!(@image.columns , @image.rows)
      @image.composite!(lomo_burn, 0, 0, Magick::ColorBurnCompositeOp)
      @image.composite!(lomo_burn, 0, 0, Magick::MultiplyCompositeOp)
      @image = @image.modulate(0.9, 1.0, 1.0)

      return @image
    end


    def savannah(params=nil)
      layer = Magick::Image.new(@image.columns, @image.rows) { self.background_color = '#F7DAAE' }
      @image.composite!(layer, 0, 0, Magick::MultiplyCompositeOp)
      @image = level_in(@image, Magick::DefaultChannels, 0, 236, 1.3)
      @image = level_out(@image, Magick::GreenChannel, 37, 255)
      @image = level_out(@image, Magick::BlueChannel, 133, 255)
      @image = @image.modulate(1.1, 1.0, 1.0)
      @image = @image.contrast(true)

      @image = level_in(@image, Magick::GreenChannel, 13, 255)
      @image = level_in(@image, Magick::BlueChannel, 88, 255)
      @image = @image.modulate(0.90, 1.0, 1.0)
      @image = @image.contrast(true)

      @image = level_out(@image, Magick::RedChannel, 4, 255)
      @image = level_out(@image, Magick::BlueChannel, 14, 255)

      return @image
    end

    def stackhouse(params=nil)
      @image = @image.modulate(1.0, 0.65, 1.0)
      @image = @image.level(0.03 * Magick::QuantumRange)

      @image = @image.level_channel(Magick::RedChannel, 0.03 * Magick::QuantumRange, Magick::QuantumRange)
      @image = @image.level_channel(Magick::GreenChannel, 0.01 * Magick::QuantumRange, Magick::QuantumRange)
      @image = @image.level_channel(Magick::BlueChannel, 0.04 * Magick::QuantumRange, Magick::QuantumRange)
      @image = @image.modulate(0.9, 1.0, 1.0)
      offwhite = Magick::Image.new(@image.columns, @image.rows) { self.background_color = '#FFF8F2' }
      @image.composite!(offwhite, 0, 0, Magick::MultiplyCompositeOp)
      @image = @image.level(0.03 * Magick::QuantumRange, Magick::QuantumRange, 0.91)
      @image = @image.level_channel(Magick::RedChannel, 0.03 * Magick::QuantumRange, Magick::QuantumRange * 0.88)
      @image = @image.level_channel(Magick::GreenChannel, 0.01 * Magick::QuantumRange, Magick::QuantumRange)
      @image = @image.level_channel(Magick::BlueChannel, 0.035 * Magick::QuantumRange, Magick::QuantumRange, 0.94)

      @image = @image.modulate(1.2, 1.0, 1.0)
      @image = @image.contrast(true)
      return @image
    end

    def vintage(params=nil)
      vignette_image = Magick::Image.read(VINTAGE_VIGNETTE).first
      white_central_light = Magick::Image.read(VINTAGE_WHITE_CENTRAL).first
      vignette_image.resize!(@image.columns , @image.rows)
      white_central_light.resize!(@image.columns , @image.rows)
      @image.composite!(white_central_light, 0, 0, Magick::OverCompositeOp)
      @image = @image.modulate(1.2, 1.6)
      @image.composite!(vignette_image, 0, 0, Magick::DarkenCompositeOp)
      return @image
    end

    def xpro(params=nil)
      layer = Magick::Image.new(@image.columns, @image.rows) { self.background_color = '#FCFFEB' }
      @image.composite!(layer, 0, 0, Magick::MultiplyCompositeOp)
      @image = @image.gamma_channel(0.77)
      @image = level_in(@image, Magick::RedChannel, 28,255, 1.09)
      @image = @image.gamma_channel(1.06, Magick::GreenChannel)
      @image = level_out(@image, Magick::BlueChannel, 45, 255)

      @image = @image.modulate(1.1, 1.0, 1.0)
      @image = @image.contrast(true)

      @image = level_in(@image, Magick::DefaultChannels, 15, 243, 1.03)
      @image = level_out(@image, Magick::DefaultChannels, 0, 238)
      @image = level_in(@image, Magick::RedChannel, 49, 255, 2.35)
      @image = level_out(@image, Magick::RedChannel, 11, 232)
      @image = level_out(@image, Magick::GreenChannel, 0, 250, 1.15)
      @image = level_out(@image, Magick::BlueChannel, 56, 238, 0.58)

      @image = @image.contrast(true)
      @image = level_out(@image, Magick::BlueChannel, 0, 241)
      @image = level_out(@image, Magick::BlueChannel, 14, 255)

      return @image
    end

    def self.save_interlace_from_name(name)
      puts "In Interlace with #{name.inspect}"
      case name
      when "UndefinedInterlace"
        return Magick::UndefinedInterlace
      when "NoInterlace"
        return Magick::NoInterlace
      when "LineInterlace"
        return Magick::LineInterlace
      when "PlaneInterlace"
        return Magick::PlaneInterlace
      when "PartitionInterlace"
        return Magick::PartitionInterlace
      when "JPEGInterlace"
        return Magick::JPEGInterlace
      when "GIFInterlace"
        return Magick::GIFInterlace
      when "PNGInterlace"
        return Magick::PNGInterlace
      end
      puts "Returning NO Interlace"
      return Magick::NoInterlace
    end

private
    def style_from_name(name, default)
      case(name.to_s.downcase)
        when "normal"
          return Magick::NormalStyle
        when "italic"
          return Magick::ItalicStyle
        when "oblique"
          return Magick::ObliqueStyle
      end

      return default
    end

    def weight_from_name(name, default)
      case (name.to_s.downcase)
      when "bold"
        return Magick::BoldWeight
      when "normal"
        return Magick::NormalWeight
      when "100"
        return 100
      when "200"
        return 200
      when "300"
        return 300
      when "400"
        return 400
      when "500"
        return 500
      when "600"
        return 600
      when "700"
        return 700
      when "800"
        return 800
      when "900"
        return 900
      end
      # Default
      return default
    end


    def interlace_from_name(name)
      puts "In Interlace with #{name.inspect}"
      case name
      when "UndefinedInterlace"
        return Magick::UndefinedInterlace
      when "NoInterlace"
        return Magick::NoInterlace
      when "LineInterlace"
        return Magick::LineInterlace
      when "PlaneInterlace"
        return Magick::PlaneInterlace
      when "PartitionInterlace"
        return Magick::PartitionInterlace
      when "JPEGInterlace"
        return Magick::JPEGInterlace
      when "GIFInterlace"
        return Magick::GIFInterlace
      when "PNGInterlace"
        return Magick::PNGInterlace
      end
      puts "Returning NO Interlace"
      return Magick::NoInterlace
    end

    def self.colorspace_from_name(name)
      case name
        when "UndefinedColorspace"
          return Magick::UndefinedColorspace
        when "RGBColorspace"
          return Magick::RGBColorspace
        when "SRGBColorspace"
          return Magick::SRGBColorspace
        when "GRAYColorspace"
          return Magick::GRAYColorspace
        when "TransparentColorspace"
          return Magick::TransparentColorspace
        when "XYZColorspace"
          return Magick::XYZColorspace
        when "CMYKColorspace"
          return Magick::CMYKColorspace
        when "HSLColorspace"
          return Magick::HSLColorspace
        when "HSBColorspace"
          return Magick::HSBColorspace
        when "YPbPrColorspace"
          return Magick::YPbPrColorspace
      end
      puts "Returning Default RGBColorspace Colorspace"

      return Magick::RGBColorspace
    end

    def gravity_from_name(name)
      case name
        when "NorthWestGravity"
          return Magick::NorthWestGravity
        when "SouthWestGravity"
          return Magick::SouthWestGravity
        when "NorthEastGravity"
          return Magick::NorthEastGravity
        when "SouthEastGravity"
          return Magick::SouthEastGravity
        when "WestGravity"
          return Magick::WestGravity
        when "EastGravity"
          return Magick::EastGravity
        when "SouthGravity"
          return Magick::SouthGravity
        when "NorthGravity"
          return Magick::NorthGravity
        when "CenterGravity"
          return Magick::CenterGravity
      end
      return Magick::CenterGravity
    end

    def level_out(image, channel, black_base_255, white_base_255, gamma = 1.0)
      return image.levelize_channel((black_base_255/255.0) *  Magick::QuantumRange,  (white_base_255/255.0) * Magick::QuantumRange,  gamma, channel)
    end

    def level_in(image, channel, black_base_255, white_base_255, gamma = 1.0)
      return image.level_channel(channel, (black_base_255/255.0) *  Magick::QuantumRange,  (white_base_255/255.0) * Magick::QuantumRange,  gamma)
    end

    def floaterize(param_value, default_value)
      if param_value
        return param_value.to_f
      end
      return default_value
    end

    def interize(param_value, default_value = 0)
      if param_value
        return param_value.to_i
      end
      return default_value
    end

    def either_below_constraints?(image, width, height)
      result_x = true
      result_y = true

      image_width = image.columns
      image_height = image.rows

      if width && width.to_i != 0
        result_x = (image_width < width) # Is image below constraint?
      end

      if height && height.to_i != 0
        result_y = (image_height < height) # Is image below constraint?
      end

      return result_x || result_y
    end

    def already_below_constraints?(image, width, height)
      result_x = true
      result_y = true

      image_width = image.columns
      image_height = image.rows

      if width && width.to_i != 0
        result_x = (image_width < width) # Is image below constraint?
      end

      if height && height.to_i != 0
        result_y = (image_height < height) # Is image below constraint?
      end

      return result_x && result_y
    end

  end
end



