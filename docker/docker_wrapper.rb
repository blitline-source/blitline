require 'blitline/job/utils'
require 'blitline/job/uploader'
require 'blitline/job/constants'
require 'blitline/job/http_client'
require 'oj'

module Blitline
	class DockerWrapper
		attr_reader :script_output

		DOCKER_IMAGE_LOCATION = "quay.io/jaciones/transient_machine"
		TEMP_BUCKET = "bltemp"
		IMG_FORMATS = [".jpg", ".png", ".jpeg"]
		INPUT_VECTOR_FORMATS = [".svg", ".eps", ".pdf", ".ai"]

		def self.run_raw_script(input_file, script, output_file)
		
		end

		def initialize(image = nil, uploader = nil)
			@image = image
			@uploader = uploader
			@script_output = ""
		end

		def self.load_screenshot(url, width = 1280, height = 640, delay=7 )
			docker = DockerWrapper.new()
			raise "Must give URL for screenshot" unless url
			delay = delay/1000 if delay > 20
			user_files = ["http://s3-us-west-1.amazonaws.com/bblobs/scripts/chromium.sh"]
			executable = "chromium.sh #{width.to_i} #{height.to_i} '#{url}' #{delay.to_i}"
			output_filepath = docker.run_docker_job("files", user_files, executable, nil, true)
			return output_filepath
		end

		def self.run_conversion_on_src(src_path, dest_extension, uploader)
			docker = DockerWrapper.new()
			raise "Must give src_path for conversion" unless src_path
			src_url = uploader.simple_upload_to_s3(src_path)
			file_extension = File.extname(src_url).downcase

			if IMG_FORMATS.include?(file_extension)
				raise "Conversion between raster formats not supported. Please just output via job functions and save"
			elsif INPUT_VECTOR_FORMATS.include?(dest_extension)
				# --- Vector Conversion
				executable = "inkscape"

				if dest_extension.downcase == ".eps"
					filename = "output.eps"
					suffix = "--export-eps=#{filename}"
				elsif dest_extension.downcase == ".svg"
					filename = "output.svg"
					suffix = "--export-plain-svg=#{filename}"
				elsif dest_extension.downcase == ".pdf"
					filename = "output.pdf"
					suffix = "--export-pdf=#{filename}"
				else
					raise "Unrecognized conversion destination extension '#{dest_extension.downcase}'. Only eps, svg, pdf supported"
				end

				shell_text = "wget  –q #{src_url} -O original#{file_extension}\n#{executable} original#{file_extension} #{suffix}\nmv #{filename} output.png"
				puts "------> #{shell_text}"
				output_filepath = docker.run_docker_job("text", nil, nil, shell_text, false)
				`mv #{output_filepath} #{output_filepath}#{dest_extension}`
				output_filepath = output_filepath + dest_extension

			else
				raise "#{file_extension} -> #{dest_extension} conversion unsupported here"
			end


			return output_filepath
		end

		def run_docker_job(type, user_files, executable, shell_text, skip_image_loading = false)
			output_filepath = "/tmp/" + Blitline::Utils.suid + ".png"
			if (type=="files")
				command_array = []
				raise "Must specify user_files and executable for type='files'" unless user_files && executable
				unless skip_image_loading
					image_url = prep_image(@image) 
					command_array << "wget -O input.png #{image_url}  \n"
				end
				user_files.each do |url|
					command_array << "wget \"#{url}\""
					filename = File.basename(url)
					command_array << "chmod +x #{filename}"
				end
				if executable[0] != "."
					executable = "./" + executable
				end
				command_array << "#{executable}"
				command_array << "mv output.png #{output_filepath}"
				command_string = command_array.join("\n")
				enc = Base64.strict_encode64(command_string)
			elsif (type=="text" && shell_text)
				if (@image)
					raise "Must specify text type='text'" unless shell_text
					unless skip_image_loading
						image_url = prep_image(@image)
						shell_text.gsub!("#!/bin/bash","")
						shell_text = "wget -O input.png #{image_url}; \n" + shell_text
					else
						shell_text.gsub!("#!/bin/bash","")
					end
				end
				shell_text = shell_text + "\n" + "mv output.png #{output_filepath}"
				enc = Base64.strict_encode64(shell_text)
			end

			docker_command = "docker run -c 2000 -e DOCKER_DATA=\"#{enc}\" -m 1000000000 -d -w '/tmp' #{DOCKER_IMAGE_LOCATION} sh run.sh"
			BlitlineLogger.log(docker_command)
			begin
				id = `#{docker_command}`.to_s.strip
				BlitlineLogger.log "id = #{id}" 
				done = false
				count = 0
				while (!done && count < 600)
					count += 1
					docker_status_command = "docker inspect #{id}"
					BlitlineLogger.log(docker_status_command)
					json_result = `#{docker_status_command}`
					result = Oj.load(json_result)
					if result && result[0] && result[0]["State"] && result[0]["State"]["Running"].to_s.downcase == "false"
						done = true
					end
					sleep(1)
				end
				logs_command = "docker logs #{id}"
				logs_output = ""
				begin
					stdin, stdout_and_stderr, wait_thr = Open3.popen2e("#{logs_command}")
					logs_output = stdout_and_stderr.read
				ensure
					stdin.close  # stdin and stdout_and_stderr should be closed explicitly in this form.
					stdout_and_stderr.close
				end
				BlitlineLogger.log "logs_output = #{logs_output}"				
				docker_cp_command = "docker cp #{id}:#{output_filepath} /tmp/"
				BlitlineLogger.log docker_cp_command
				output = `#{docker_cp_command}`
				BlitlineLogger.log output
			ensure
				docker_kill_command = "docker kill #{id}"
				BlitlineLogger.log(docker_kill_command)
				success = `#{docker_kill_command}`


				docker_remove_command = "docker rm #{id}"
				BlitlineLogger.log(docker_remove_command)
				success = `#{docker_remove_command}`
			end

			unless File.exists? output_filepath
				raise "Failed to complete script. Output from script = #{logs_output}"
			end

			return output_filepath
		end

		def prep_image(image)
			bucket = TEMP_BUCKET
			key = "#{Blitline::Utils.suid}/#{Blitline::Utils.suid}.png"
			url = @uploader.upload_to_s3_from_image(image, bucket, key)
			wait_for_s3([url])
			return url
		end

		def wait_for_s3(s3_urls)
			1.upto(20) do
				all_exist = true
				s3_urls.each do |url|
					unless Blitline::HttpClient.exists?(url)
						all_exist = false
						BlitlineLogger.log "...waiting"
						break;
					end
				end
				return if all_exist
				sleep 0.2
			end
		end

	end
end