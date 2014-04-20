module Blitline
  module ExternalTools
    require 'digest'
    require "zlib"
    require "open-uri"
    require "timeout"
    require "blitline/job/docker/docker_wrapper"

    DEFAULT_PDF_VALIDATE_PATH = "/tmp/validate_pdf6.sh"
    DEFAULT_PDF_BURST_PATH = "/tmp/burst_pdf4.sh"
    DEFAULT_CONVERT_VALIDATE_PATH = "/tmp/convert_command.sh"
    DEFAULT_ENHANCE_PATH = "/tmp/enhance.sh"

    PUBLIC_PATH = File.exists?("/u/apps/blitline/current/public") ? "/u/apps/blitline/current/public" : ( File.exists?("/Users/jason/workspace/blitline/public") ? "/Users/jason/workspace/blitline/public" : "/home/ubuntu/workspace/blitline/public")
  	PHANTOM_PATH = File.exists?("/home/ubuntu/phantomjs/bin/phantomjs") ? "/home/ubuntu/phantomjs/bin/phantomjs --web-security=false --ssl-protocol=any --ignore-ssl-errors=true #{PUBLIC_PATH}/javascripts/phantom/screen_shot.js" : "phantomjs --web-security=false --ssl-protocol=any --ignore-ssl-errors=true #{PUBLIC_PATH}/javascripts/phantom/screen_shot.js"
    GIFSICLE_PATH = "gifsicle"

    DOCKER_IMAGE_LOCATION = "quay.io/jaciones/transient_machine"

    def self.docker(image, uploader, type, user_files, executable, shell_text)
      docker = Blitline::DockerWrapper.new(image, uploader)
      output_filepath = docker.run_docker_job(type, user_files, executable, shell_text)

      begin
        @return_image = Magick::Image.read(output_filepath).first
      ensure
        FileUtils.rm output_filepath if File.exists? output_filepath
      end

      return @return_image
    end

  	def screen_shot(url, output_path, width = 1024, viewport = nil, delay = 5000, output_html = "")
      begin
  			raise "Invalid screenshot_params" unless url && output_path
        url = url.to_s.gsub("'"," %27")
        url = url.to_s.gsub(";","")
        url = url.to_s.gsub("|","")

        output = "" if output_html.to_s=="false"
        raise "Delay cannot be greater than 30000 (30 seconds)" if delay.to_i > 30000
        third_param = viewport ? " '#{viewport[0]}x#{viewport[1]}'" : " #{width}"
        execution_string = PHANTOM_PATH + " '" + url.to_s + "' " + output_path + third_param + " #{delay.to_s} " + output_html.to_s
        BlitlineLogger.log(execution_string)
  			success =  system(execution_string)
        raise "PJS failed to generate screenshot #{output_path} --> #{success.inspect}" unless success
        raise "Failed to generate screenshot for \"#{url}\"" unless File.exists? output_path
  		rescue => ex
        BlitlineLogger.log(ex)
  			BlitlineLogger.log("Screenshot failed for " + url.to_s + ":" + output_path)
  			raise "Screenshot attempt for '#{url}' failed, please check url to make sure it's available. This incident has been logged and will be looked into..."
  	  end
    end

    def docker_screen_shot(url, width, height, delay)
      output_path = Blitline::DockerWrapper.load_screenshot(url, width, height, delay)
      return output_path
    end

    # gifsicle --resize-width 200 --colors 256 1970s-automatic-chronograph-orig.gif > out.gif
    def resize_gif(type, src, output_path, params)
      begin
        width = nil
        height = nil
        width_val = params["width"].to_i
        height_val = params["height"].to_i

        width = width_val > 0 ? width_val.to_s : "_"
        height = height_val > 0 ? height_val.to_s : "_"
        if type == :resize
          action = "--resize #{width}x#{height}"
        elsif type == :resize_to_fit
          action = "--resize-fit #{width}x#{height}"
        end
        action.gsub!(";","")
        action.gsub!("|","")

        execution_string = "#{GIFSICLE_PATH} #{action} --colors 256 #{src} > #{output_path}"
        puts "#{execution_string}"
        success = system(execution_string)
        raise "Gif failed to generate GIF #{output_path} --> #{success.inspect}" unless success
        raise "Failed to generate GIF for \"#{url}\"" unless File.exists? output_path
      rescue => ex
        BlitlineLogger.log(ex)
        BlitlineLogger.log("Resize GIF failed for " + src.to_s + ":" + output_path.to_s + ":" + params.to_s)
        raise "Error resizing GIF."
      end
    end

    def self.get_hash(hash_type, file_url)
      hash_type = hash_type.downcase.to_sym
      file_contents  = open(file_url, 'rb') {|f| f.read }

      if hash_type == :md5
        digest = Digest::MD5.hexdigest(file_contents)
      elsif hash_type == :sha256
        digest = Digest::SHA256.hexdigest(file_contents)
      elsif hash_type == :crc32
        digest = Zlib.crc32(file_contents)
      else
        raise "Hash type not found, valid values are: 'md5', 'sha256', or 'crc32'"
      end

      return digest
    end

    def self.copy_profiles

      begin
        unless File.exists?("/tmp/AdobeRGB.icc")
          src_dir = Dir.pwd
          if File.exists?(src_dir + "/profiles/RGB/AdobeRGB1998.icc")
            FileUtils.cp(src_dir + "/profiles/RGB/AdobeRGB1998.icc", "/tmp/AdobeRGB.icc")
            FileUtils.cp(src_dir + "/profiles/CMYK/USWebUncoated.icc", "/tmp/USWebUncoated.icc")
          elsif File.exists?(src_dir + "/lib/profiles/RGB/AdobeRGB1998.icc")
            FileUtils.cp(src_dir + "/lib/profiles/RGB/AdobeRGB1998.icc", "/tmp/AdobeRGB.icc")
            FileUtils.cp(src_dir + "/lib/profiles/CMYK/USWebUncoated.icc", "/tmp/USWebUncoated.icc")
          elsif File.exists?("/u/apps/blitline/current/lib/profiles/RGB/AdobeRGB1998.icc")
            FileUtils.cp("/u/apps/blitline/current/lib/profiles/RGB/AdobeRGB1998.icc", "/tmp/AdobeRGB.icc")
            FileUtils.cp("/u/apps/blitline/current/lib/profiles/CMYK/USWebUncoated.icc", "/tmp/USWebUncoated.icc")
          else
            raise "Can't file profiles @ " + src_dir + "/profiles/RGB/AdobeRGB1998.icc"
          end
        end
      rescue => ex
        BlitlineLogger.log(ex)
      end

    end

    def self.create_auto_enhance_shell_file
      begin
        unless File.exists?(DEFAULT_ENHANCE_PATH)
          BlitlineLogger.log("Writing #{DEFAULT_ENHANCE_PATH}...")
          File.open(DEFAULT_ENHANCE_PATH, 'w') do |f|
            f.puts("convert $1 -channel rgb -auto-level $2")
            f.puts("result=$(convert  $1  -colorspace hsb  -resize 1x1  txt:-)")
            f.puts(" ")
            f.puts("[[ $result =~ ([0-9][0-9])\.[0-9]*%\\) ]]")
            f.puts("percent=${BASH_REMATCH[1]}")
            f.puts("if ((\"$percent\" > \"70\"))")
            f.puts("   then echo;")
            f.puts("   convert $1 -channel rgb -auto-gamma -auto-level $2")
            f.puts("fi")
            f.puts("if ((\"$percent\" < \"30\"))")
            f.puts("   then echo;")
            f.puts("   convert $1 -channel rgb -auto-gamma -auto-level $2")
            f.puts("fi")
            f.puts("rm $1")
            f.puts("exit 0")
          end
          File.chmod(0700, DEFAULT_ENHANCE_PATH)
        end
      rescue => ex
        BlitlineLogger.log(ex)
        BlitlineLogger.log("Continuing...")
      end      
    end


    def self.create_pdf_burst_shell_file
      begin
        unless File.exists?(DEFAULT_PDF_BURST_PATH)
          BlitlineLogger.log("Writing #{DEFAULT_PDF_BURST_PATH}...")
          File.open(DEFAULT_PDF_BURST_PATH, 'w') do |f|
            f.puts("pdfseparate $1 $2/page_%04d.pdf%%d")
            f.puts("for file in $2/*%d; do")
            f.puts("    di=$(dirname $file)")
            f.puts("    bn=$(basename $file %d)")
            f.puts("    mv \"$file\" \"$di/$bn\"")
            f.puts("done")
            f.puts("")
            f.puts("OUT=$?")
            f.puts("if [ $OUT -eq 0 ];then")
            f.puts("   exit 0")
            f.puts("else")
            f.puts("    echo 'falling back to pdftk'")
            f.puts("    pdftk $1 output /tmp/Fixed$$.pdf")
            f.puts("    rm  $1")
            f.puts("    mv /tmp/Fixed$$.pdf $1")
            f.puts("    pdftk $1 burst output $2/page_%04d.pdf")
            f.puts("    OUT=$?")
            f.puts("    if [ $OUT -eq 0 ];then")
            f.puts("        exit 0")
            f.puts("    else")
            f.puts("        exit -1")
            f.puts("    fi")
            f.puts("fi")
          end
          File.chmod(0700, DEFAULT_PDF_BURST_PATH)
        end
      rescue => ex
        BlitlineLogger.log(ex)
        BlitlineLogger.log("Continuing...")
      end
    end

    def self.create_pdf_info_shell_file
      begin
        unless File.exists?(DEFAULT_PDF_VALIDATE_PATH)
          BlitlineLogger.log("Writing #{DEFAULT_PDF_VALIDATE_PATH}...")
          File.open(DEFAULT_PDF_VALIDATE_PATH, 'w') do |f|
            f.puts("pdfinfo $1")
            f.puts("exit 0")
          end
          File.chmod(0700, DEFAULT_PDF_VALIDATE_PATH)
        end
      rescue => ex
        BlitlineLogger.log(ex)
        BlitlineLogger.log("Continuing...")
      end
    end

    def self.create_convert_info_shell_file
      begin
        unless File.exists?(DEFAULT_CONVERT_VALIDATE_PATH)
          BlitlineLogger.log("Writing #{DEFAULT_CONVERT_VALIDATE_PATH}...")
          File.open(DEFAULT_CONVERT_VALIDATE_PATH, 'w') do |f|
            f.puts("convert $1 $2 $3")
            f.puts("echo OK")
            f.puts("exit 0")
          end
          File.chmod(0700, DEFAULT_CONVERT_VALIDATE_PATH)
        end
      rescue => ex
        BlitlineLogger.log(ex)
        BlitlineLogger.log("Continuing DEFAULT_CONVERT_VALIDATE_PATH...")
      end
    end

    def self.auto_enhance(filepath, output_filepath)
      text_result = ""
      begin
        execution_string = "#{DEFAULT_ENHANCE_PATH} \"#{filepath}\" \"#{output_filepath}\""
        BlitlineLogger.log("Enhancing..." + execution_string)
        Timeout::timeout(15) do
          text_result = `#{execution_string}`
        end
        BlitlineLogger.log(text_result)
      rescue => ex
        BlitlineLogger.log(ex)
        BlitlineLogger.log("Continuing...")
      end
    end

   def self.burst_pdf(filepath, output_folder)
      text_result = ""
      begin
        execution_string = "#{DEFAULT_PDF_BURST_PATH} \"#{filepath}\" \"#{output_folder}\""
        BlitlineLogger.log("Burst..." + execution_string)
        begin
          Timeout::timeout(60) do
            text_result = `#{execution_string}`
          end
        rescue
          sleep(1)
          BlitlineLogger.log("Retrying Burst..." + execution_string)
          Timeout::timeout(60) do
            text_result = `#{execution_string}`
          end
        end
        BlitlineLogger.log(text_result)
      rescue => ex
        BlitlineLogger.log(ex)
        BlitlineLogger.log("Continuing...")
      end
    end

    def self.check_pdf_info(filepath)
      text_result = ""
      begin
        execution_string = "#{DEFAULT_PDF_VALIDATE_PATH} \"#{filepath}\""
        text_result = `#{execution_string}`
      rescue => ex
        BlitlineLogger.log(ex)
        BlitlineLogger.log("Continuing...")
      end

      return text_result
    end

    def self.convert_to_png8(filepath, speed)
      speed = 5 if speed.nil?
      speed = speed.to_i

      execution_string = "pngquant --ext .png --speed #{speed} --force \"#{filepath}\""
      success = system(execution_string)
      raise "Convert to PNG8 failed. #{success.inspect}" unless success
    end


    def self.validate_convert_params(params)
      params.each do |key, value|
        raise "Param (#{key}) must have a dash or plus before it" unless (key[0]=="-" || key[0]=="+")
        raise "Command (#{key}) not Found" unless MAGICK_COMMANDS.include?(key.reverse.chop.reverse)
        if value.is_a?(Array)
          value.each do |value_item|
            raise "Invalid params value (#{value_item}), only letters, numbers, and the symbols -,@,#,%,+,$,^,:,!,., and a comma" if value_item.match(/[^a-zA-Z0-9\@\:\#\!\%\+\$\^\ \,\.\-]/)
          end
        else
          raise "Invalid params value (#{value}), only letters, numbers, and the symbols -,@,#,%,+,$,^,:,!,., and a comma" if value.match(/[^a-zA-Z0-9\@\:\#\!\%\+\$\^\ \,\.\-]/)
        end
        raise "Individual params (#{value}) must be less than 60 characters" if value.length > 59
      end
    end

    # convert
    # " $animation -coalesce -gravity South -geometry +0+0 null: $overlay_src -layers composite -layers optimize "
    def self.run_gif_composite(params, input_filepath, overlay_src, output_filepath)
      geometry = params["geometry"] || "-geometry +0+0 null:"
      geometry = geometry.gsub("'"," %27").gsub(";","").gsub("|","")
      gravity = params["gravity"] || "Center"
      gravity = gravity.gsub("'"," %27").gsub(";","").gsub("|","")

      formatted_params = " -coalesce -gravity #{gravity} #{geometry} #{overlay_src} -layers composite -layers optimize "
      begin
        execution_string = "#{DEFAULT_CONVERT_VALIDATE_PATH} #{input_filepath} '#{formatted_params}' #{output_filepath}"
        BlitlineLogger.log(execution_string)
        text_result = `#{execution_string}`
      end

      success = text_result.include?("OK")
      raise "Convert command failed. #{success.inspect}" unless success
    end

    def self.run_convert_command(params, input_filepath, output_filepath)
      validate_convert_params(params)
      formatted_params = format_convert_params(params)
      text_result = "Failed to run convert"
      begin
        execution_string = "#{DEFAULT_CONVERT_VALIDATE_PATH} #{input_filepath} \"#{formatted_params}\" #{output_filepath}"
        BlitlineLogger.log(execution_string)
        text_result = `#{execution_string}`
      end

      success = File.exists?(output_filepath)
      raise "Convert command failed. #{text_result.inspect}" unless success
    end

    def self.unsafe_convert_command(formatted_params, input_filepath, output_filepath)
      text_result = "Failed to run convert"
      begin
        execution_string = "#{DEFAULT_CONVERT_VALIDATE_PATH} #{input_filepath} \"#{formatted_params}\" #{output_filepath}"
        BlitlineLogger.log(execution_string)
        text_result = `#{execution_string}`
      end

      success = File.exists?(output_filepath)
      raise "Convert command failed. #{text_result.inspect}" unless success
    end

    def self.run_conversion_on_src(input_filepath, input_extension, output_extension, uploader)
      return_filepath = Blitline::DockerWrapper.run_conversion_on_src(input_filepath, output_extension, uploader)
      return return_filepath
    end

    def self.convert_to_rgb(image)
      if image.colorspace == Magick::CMYKColorspace
        image.strip!
        image.add_profile("#{Rails.root}/lib/profiles/CMYK/USWebCoatedSWOP.icc")
        image.colorspace = Magick::SRGBColorspace
        image.add_profile("#{Rails.root}/lib/profiles/RGB/AdobeRGB1998.icc")
      end
      image
    end

    def self.format_convert_params(params)
      new_params = []
      params.each do |key, value|
        if value.is_a?(Array)
          value.each do |value_item|
            new_params << "#{key} #{value_item}"
          end
        else
          new_params << "#{key} #{value}"
        end
      end
      return new_params.join(" ")
    end

    MAGICK_COMMANDS = [ "adaptive-blur", "adaptive-resize", "adaptive-sharpen", "adjoin", "affine", "alpha", "annotate", "antialias", "append", "attenuate", "authenticate", "auto-gamma",
      "auto-level", "auto-orient", "backdrop", "background", "bench", "bias", "black-point-compensation", "black-threshold", "blend", "blue-primary", "blue-shift", "blur", "border", "bordercolor",
      "borderwidth", "brightness-contrast", "cache", "caption", "cdl", "channel", "charcoal", "chop", "clamp", "clip", "clip-mask", "clip-path", "clone", "clut", "coalesce", "colorize", "colormap",
      "color-matrix", "colors", "colorspace", "combine", "comment", "compose", "composite", "compress", "contrast", "contrast-stretch", "convolve", "crop", "cycle", "deconstruct",
      "define", "delay", "delete", "density", "depth", "descend", "deskew", "despeckle", "direction", "displace", "dispose", "dissimilarity-threshold", "dissolve", "distort", "distribute-cache",
      "dither", "draw", "duplicate", "edge", "emboss", "encipher", "encoding", "endian", "enhance", "equalize", "extent", "extract", "family", "features", "fft", "fill", "filter", "function",
      "flatten", "flip", "floodfill", "flop", "font", "foreground", "format", "format[identify]", "frame", "frame[import]", "fuzz", "fx", "gamma", "gaussian-blur", "geometry", "gravity", "green-primary",
      "hald-clut", "help", "highlight-color", "iconGeometry", "iconic", "identify", "ift", "immutable", "implode", "insert", "intent", "interlace", "interpolate", "interline-spacing", "interword-spacing", "kerning",
      "label", "lat", "layers", "level", "level-colors", "limit", "linear-stretch", "linewidth", "liquid-rescale", "list", "lowlight-color", "magnify", "map", "map[stream]", "mask",
      "mattecolor", "median", "metric", "mode", "modulate", "monitor", "monochrome", "morph", "morphology", "mosaic", "motion-blur", "name", "negate", "noise", "normalize", "opaque", "ordered-dither",
      "orient", "page", "paint", "path", "pause[animate]", "pause[import]", "pen", "perceptible", "pointsize", "polaroid", "poly", "polynomial_function", "posterize", "precision", "preview", "profile",
      "quality", "quantize", "quiet", "radial-blur", "raise", "random-threshold", "red-primary", "regard-warnings", "region", "remap", "remote", "render", "repage", "resample", "resize",
      "reverse", "roll", "rotate", "sample", "sampling-factor", "scale", "scene", "seed", "segment", "selective-blur", "separate", "sepia-tone", "set", "shade", "shadow", "sharpen",
      "shave", "shear", "sigmoidal-contrast", "silent", "size", "sketch", "smush", "snaps", "solarize", "sparse-color", "splice", "spread", "statistic", "stegano", "stereo", "stretch", "strip", "stroke", "strokewidth",
      "style", "subimage-search", "swap", "swirl", "synchronize", "taint", "text-font", "texture", "threshold", "thumbnail", "tile", "tile-offset", "tint", "title", "transform", "transparent", "transparent-color",
      "transpose", "transverse", "treedepth", "trim", "type", "undercolor", "unique-colors", "units", "unsharp", "update", "verbose", "version", "view", "vignette", "virtual-pixel", "visual", "watermark", "wave",
      "weight", "white-point", "white-threshold", "window" ]
  end
end