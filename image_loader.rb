module Blitline
	class ImageLoader
		MULTI_IMAGE_FILETYPES = [".pdf", ".tiff"]
		SVG_TYPE = ".svg"
		DOWNLOAD_FILE_DIR = Dir.tmpdir
		COLOR_PROFILES = ["cmyk", "rgb", "hsl", "gray", "lab", "transparent"]
		INFO_FIELDS = ["antialias","attenuate","authenticate","background_color","border_color","caption","colorspace","comment","compression","delay","density","depth","dispose","dither","endian","extract","filename","fill","font","format","fuzz","gravity","image_type","interlace","label","matte_color","monitor","monochrome","orientation","origin","page","pointsize","quality","sampling_factor","scene","server_name","size","stroke","stroke_width","tile_offset","texture","transparent_color","undercolor","units","view"]

		def initialize(uploader, message_wrapper, image_cache, raw_data, results)
			@uploader = uploader
			@message_wrapper = message_wrapper
			@image_cache = image_cache
			@raw_data = raw_data
			@results = results
		end

		def get_key_or_filename(src)
			if src.is_a?(Hash) 
				bucket = src['bucket']
				key = src['key']
				return key.to_s
			end
			return src.to_s
		end

		def shortcut_checks(raw_data, src)
			if src
				# Load SVG specially
				extname = File.extname(get_key_or_filename(src)).split("?")
				if extname && extname[0]
					if File.extname(get_key_or_filename(src)).split("?")[0].to_s.downcase == SVG_TYPE
						image = load_svg(@raw_data)
						return image
					end
				end
			end
			# Load S3 Src
			if src.is_a?(Hash)
				image = load_complex_source(@raw_data, @uploader)
				return image
			end
			
			# See if we can load from cache
			result = grab_from_cache_first(src, @image_cache)

			return result
		end

		def load_original_image(src, src_data, src_type)
			image = shortcut_checks(@raw_data, src)
			return image if image

			src_url = Blitline::Utils.attempt_to_gracefully_handle_url(src)
			if src_type == Blitline::Constants::SRC_TYPE_IMAGE || src_type == Blitline::Constants::SRC_TYPE_INLINE

				# Regular load pre_load_function_items
				skip_to_regular_load = @raw_data && @raw_data["src_data"] && @raw_data["src_data"]["pre_load_function"] && @raw_data["src_data"]["pre_load_function"]["name"] == "convert_command"

				if MULTI_IMAGE_FILETYPES.include?(File.extname(src_url.to_s).split("?")[0].to_s.downcase) 
					BlitlineLogger.log("Multi-Image LOAD")

					image_list = try_load_image_list_from_local_download(src_url, src_data, @raw_data)

					if (image_list.length > 0)
						begin # Try appending them. Then fall-back to first
							image = image_list.append(true)
						rescue
							image = image_list[0]
						end
					else
						image = image_list[0]
					end
					image.alpha(Magick::DeactivateAlphaChannel)
				else
					begin
						inline_image = (src_type == Blitline::Constants::SRC_TYPE_INLINE)
						image = try_load_from_local_download(src_url, inline_image)
						raise "Failed to load" if image.nil?
						#image = Magick::Image.read(src_url).first
					rescue => image_exception
						@message_wrapper.touch
						raise "Failed to load image at #{src_url.to_s}, are you sure it is accessible at that url? (Exception Message=:#{image_exception.message}" unless image
					end
				end
			elsif src_type == Blitline::Constants::SRC_TYPE_SCREEN_SHOT
				width = 1024
				viewport = nil
				delay = 5000

				if src_data
					if src_data['width']
						width = src_data['width'].to_i
					end

					if src_data['viewport']
						viewport = src_data['viewport'].split("x")
						viewport[0] = viewport[0].to_i
						viewport[1] = viewport[1].to_i
					end

					if src_data['chrome_render']
						raise "Chrome ONLY supports viewport for rendering. Must by WIDTH x HEIGHT (ie. 1240x640)" unless src_data['viewport']
						width = viewport[0]
						height = viewport[1]
					end

					if src_data['delay']
						delay = src_data['delay'].to_i
					end

					output_html = false
					if src_data["save_html"]
						output_html = true
					end

				end

				download_file_directory = DOWNLOAD_FILE_DIR
				tmp_file = File.join(download_file_directory,  Blitline::Utils.suid + ".png")
				begin
					@message_wrapper.touch
					raise "Url is not available. Perhaps it behind an auth dialog or it's returning and error(non 200 response)" unless Blitline::HttpClient.url_available?(src_url)
					@message_wrapper.touch
					if src_data && src_data['chrome_render']
						tmp_file = Blitline::ImageProcessor.docker_screen_shot(src_url, width, height, delay)
					else
						Blitline::ImageProcessor.screen_shot(src_url, tmp_file, width, viewport, delay, output_html)
					end
					image = Magick::Image.read(tmp_file).first
					if output_html
						push_html_to_storage(tmp_file + ".html", src_data['save_html'])
					end
				ensure
					FileUtils.rm tmp_file if File.exists? tmp_file
				end
			elsif src_type == Blitline::Constants::SRC_TYPE_MULTI_PAGE || (src_type.is_a?(Hash) &&  src_type['name'] == Blitline::Constants::SRC_TYPE_MULTI_PAGE)
				image_list = nil
				begin
					image_list = try_load_image_list_from_local_download(src_url, src_data, @raw_data)
					images = image_list.to_a
					images.each do |single_image|
						single_image.alpha(Magick::DeactivateAlphaChannel)
					end
					return images
				rescue => ex
					BlitlineLogger.log(ex)
					if image_list && image_list.to_a
						image_list.to_a.each do |image_to_destroy|
							image_to_destroy.destroy!
						end
						GC.start
						@message_wrapper.touch
					end
					raise "Failed to load image #{ex.backtrace.join('')}"
				end
			else
				raise "Unknow src_type. Internal error that shouldnt ever happen."
			end

			return image
		end

		def try_load_from_local_download(src, use_inline = false)
			download_file_directory = DOWNLOAD_FILE_DIR
			tmp_file = File.join(download_file_directory, Blitline::Utils.suid + Blitline::HttpClient.derive_file_extension(src))
			begin
				tmp_file = Blitline::HttpClient.download_file(src, tmp_file)
				unless use_inline
					image =  handle_load_with_preload_params(@raw_data, tmp_file)
				else
					image_string = File.open(tmp_file, 'rb') { |f| f.read }
					image =  Magick::Image.read_inline(image_string).first
				end

				return image
			rescue => ex
				BlitlineLogger.log(ex)
				raise ex
			ensure
				FileUtils.rm tmp_file if File.exists? tmp_file
			end
		end

		def try_load_image_list_from_local_download(src, src_data = nil, data = nil)
			download_file_directory = DOWNLOAD_FILE_DIR
			file_extension = Blitline::HttpClient.derive_file_extension(src)
			tmp_file = File.join(download_file_directory,  Blitline::Utils.suid + file_extension)
			begin
				tmp_file = Blitline::HttpClient.download_file(src, tmp_file)
				if File.extname(src.to_s)==".pdf"
					results = Blitline::ExternalTools.check_pdf_info(tmp_file)
					pdf_info = {}
					results.split("\n").each do |row|
						pdf_info[row.split(":")[0]] = row.split(":")[1].strip					
					end

					if data["extended_metadata"].to_s == "true"
						data["passthrough_metadata"] = pdf_info
					end

					if data && data["large_pdf"].to_s != "true"
				      if pdf_info && pdf_info["Pages"].to_i > 20
				        BlitlineLogger.log("PDF errored upon loading...")
				        raise "PDF Error: cannot have more than 20 pages. This PDF is too large for us to parse as an image"
				      end
					end
				end

				begin
					if File.extname(tmp_file).to_s.downcase == ".tif" || File.extname(tmp_file).to_s.downcase == ".tiff"
						BlitlineLogger.log "Stripping2 #{tmp_file}"
						`exiv2 -pt #{tmp_file} | grep /0 | awk '{print $1}' | while read line ; do exiv2 -M"del $line" #{tmp_file}; done`						
					end
				rescue => subex
					BlitlineLogger.log(ex)
				end

				image_list =  Magick::ImageList.new(tmp_file) {
					load_density = 200
					if src_data && src_data["dpi"]
						load_density = src_data["dpi"].to_i
						if load_density < 72
							load_density = 72
						elsif load_density > 900
							load_density = 900
						end
					end

					self.density = load_density
					if src_data && (src_data['user_cropbox'] || src_data['use_cropbox'])
						self["pdf", "use-cropbox"] = 'true'
					end

					if src_data && src_data["info"]
						src_data["info"].each do |key,value|
							if INFO_FIELDS.include?(key.to_s)
								BlitlineLogger.log("Setting INFO #{key}=#{value}")
								self[key.to_s] = value.to_s
							end
						end
					end

					if src_data && src_data['colorspace']
						self.colorspace = Blitline::ImageProcessor.colorspace_from_name(src_data['colorspace'])
					end
				}
				return image_list
			ensure
				FileUtils.rm tmp_file if File.exists? tmp_file
			end
		end

		def load_canvas(width, height, background_color)
			image = Magick::Image.new(width.to_i, height.to_i) {
				self.background_color = background_color
			}
			return image
		end

		def load_svg(raw_data)
			begin
				if raw_data['src']['bucket']
					bucket = raw_data['src']['bucket']
					key = raw_data['src']['key']
					local_temp_path = @uploader.download_from_s3(key, bucket)
				else
					local_temp_path = Blitline::HttpClient.download_file(raw_data['src'])
				end

				raise "Unable to download SVG" unless local_temp_path && local_temp_path.length > 0

				remote_filename = Blitline::Utils.suid + ".svg"
				p raw_data.inspect
				temp_remote_location = raw_data["application_id"] + "/" + remote_filename
				remote_location = @uploader.upload_to_s3(local_temp_path, "bltemp.shortlife", temp_remote_location, {}, nil)
			ensure
				FileUtils.rm local_temp_path if local_temp_path && File.exists?(local_temp_path)
			end

			download_part = "wget -U 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_6_8) AppleWebKit/537.17 (KHTML, like Gecko) Chrome/24.0.1312.52 Safari/537.17' --no-check-certificate -nv --timeout=60 -t 2 -O '#{remote_filename}' '#{remote_location}'"
			rasterize_part = "rasterizer #{remote_filename} -d output.png"

			bash_string = "#{download_part}\n#{rasterize_part}"
			image = Blitline::ExternalTools.docker(nil, @uploader, "text", [], "", bash_string)
			return image
		end

		def handle_load_with_preload_params(raw_data, tmp_file)
			begin # Manage Tiff /0 problems
				if File.extname(tmp_file).to_s.downcase == ".tif" || File.extname(tmp_file).to_s.downcase == ".tiff"
					BlitlineLogger.log "Stripping3 #{tmp_file}"
					`exiv2 -pt #{tmp_file} | grep /0 | awk '{print $1}' | while read line ; do exiv2 -M"del $line" #{tmp_file}; done`
				end
			rescue => subex
				BlitlineLogger.log(ex)
			end

			begin # Handle AI or EPS
				vector_density = 200
				colorspace = "transparent"
				if raw_data && raw_data["src_data"]
					if raw_data["src_data"]["density"]
						vector_density = raw_data["src_data"]["density"].to_i
						if vector_density < 0 or vector_density > 900
							vector_density = 200
						end
					end
					if raw_data && raw_data["src_data"]["colorspace"]
						if COLOR_PROFILES.include?(raw_data["src_data"]["colorspace"].downcase)
							colorspace = raw_data["src_data"]["colorspace"]
						else
							raise "Invalid colorspace #{raw_data["src_data"]["colorspace"]}, Blitline only allows #{COLOR_PROFILES.join(',')}"
						end
					end
				end
				tmp_file = handle_colorspace_convert(tmp_file, colorspace, vector_density)


			rescue => subex
				BlitlineLogger.log(subex)
				raise
			end

			temp_output_filepath = ""
			image = nil

			begin
				if raw_data && raw_data["src_data"] && raw_data["src_data"]["pre_load_function"]
					preload_name = raw_data["src_data"]["pre_load_function"]["name"]
					preload_params = raw_data["src_data"]["pre_load_function"]["params"]
					if preload_name == "convert_command"
						temp_output_filepath = tmp_file + ".png"
						Blitline::ExternalTools.run_convert_command(preload_params, tmp_file, temp_output_filepath)
						tmp_file = temp_output_filepath
					end
				end
				image = Magick::Image.read(tmp_file).first
			ensure
				FileUtils.rm tmp_file if File.exists? tmp_file
				FileUtils.rm temp_output_filepath if File.exists? temp_output_filepath
			end

			return image
		end

		def handle_colorspace_convert(tmp_file, colorspace, vector_density)
			return_url = tmp_file

			if File.extname(tmp_file).to_s.downcase == ".eps" || File.extname(tmp_file).to_s.downcase == ".ai"
				return_url = tmp_file + ".png"
				BlitlineLogger.log "-- Vector convert #{tmp_file} to #{tmp_file}.png #{vector_density}:#{colorspace}"
				`convert -alpha on -colorspace #{colorspace} -density #{vector_density} #{tmp_file} #{return_url}`
				FileUtils.rm tmp_file if File.exists? tmp_file
				return return_url
			end

			if colorspace && colorspace != "transparent"
				BlitlineLogger.log "-- Colorspace conversion"
				if colorspace=="AdobeRGB" || colorspace.downcase=="adobergb" || colorspace.downcase=="rgb"
					return_url = tmp_file + ".png"
					`convert #{tmp_file} -profile /tmp/USWebCoatedSWOP.icc -profile /tmp/AdobeRGB.icc #{return_url}`
					FileUtils.rm tmp_file if File.exists? tmp_file
					return return_url
				end
			end

			return return_url
		end

		def load_complex_source(raw_data, uploader)
			image = nil
			begin
				if raw_data['src']['name'].downcase == "s3"
					bucket = raw_data['src']['bucket']
					key = raw_data['src']['key']
					src_url = uploader.download_from_s3(key, bucket)
					image = handle_load_with_preload_params(raw_data, src_url)
				elsif raw_data['src']['name'].downcase == "canvas"
					width = raw_data['src']['width'] || 10
					height = raw_data['src']['height'] || 10
					background_color = raw_data['src']['color'] || "#ffffff"
					image = load_canvas(width, height, background_color)
				else
					raise "Unknown Complex Source"
				end
			ensure
				FileUtils.rm src_url if (src_url && File.exists?(src_url))
			end
			return image
		end

		def grab_from_cache_first(src, image_cache)
			if src && src[0]==("&")
				image_key = src.reverse.chop.reverse
				image = image_cache[image_key]
				raise "Image reference '#{image_key}'' not found. Preprocessing probably failed." unless image
				return image
			end
			return nil
		end

		def push_html_to_storage(file_path, data)
			raise "Unable to push html to storage" unless file_path && data
			return_data = {}

			if data['s3_destination'].nil? && data['azure_destination'].nil?
				folder = File.basename(file_path, ".html") + rand(10).to_s
				name =File.basename(file_path)

				data['s3_destination'] = {
					"bucket" => "blitline",
					"key" => "#{folder}/#{name}"
				}
			end

			if data['s3_destination'] || data['azure_destination']
				# Prepare save info
				if data['s3_destination']
					bucket = data['s3_destination']['bucket']
					key = data['s3_destination']['key']
				end

				if data['s3_destination']
					canonical_id = (@raw_data["config"] && @raw_data["config"]["canonical_id"]) ? @raw_data["config"]["canonical_id"] : nil
					public_token = (@raw_data["config"] && @raw_data["config"]["public_token"]) ? @raw_data["config"]["public_token"] : nil

                    headers = {
                    	"content-type" => "text/html"
                    }

					headers.merge!(data['s3_destination']['headers']) if data['s3_destination']['headers']

					return_data['s3_url'] = @uploader.upload_to_s3(file_path, bucket, key, headers, canonical_id, public_token)

					if return_data['s3_url'].is_a?(Hash) && return_data['s3_url'][:error]
						return_data['error'] = return_data['s3_url'][:error]
						return_data.delete('s3_url')
					end
				else  # Azure destination
					account_name = data['azure_destination']['account_name']
					shared_access_signature = data['azure_destination']['shared_access_signature']
					return_data['azure_url'] = @uploader.upload_to_azure(account_name, shared_access_signature, file_path, headers)
				end
			end
			@results.push({ :save_html => return_data })
		end


	end
end