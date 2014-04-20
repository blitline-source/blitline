require 'zipruby'

module Blitline
	class Zipper

		def initialize(data, uploader, config)
			@data = data
			@load_delta = 0
			@function_delta = 0
			@uploader = uploader
			@config = config
		end

		def execute
			destination_urls = []
			run_results = []
			begin
				max_size = @data["src_data"] ?  @data["src_data"]["preferred_zip_size"] : nil
				run_results = run(@data["src"]["urls"], max_size)
				run_results.sort!

				destination = @data["src_data"]["s3_destination"]
				bucket = destination['bucket']
				key = destination['key']
				ext = File.extname(key)
				if (ext.downcase != ".zip")
					key = key + ".zip"
				end
				headers = destination['headers']

				run_results.each_with_index do |file_path, index|
					begin
						new_key = Blitline::Uploader.append_index_to_filepath(key, index)
						destination_urls << @uploader.upload_to_s3(file_path, bucket, new_key, headers, @config['canonical_id'], @config['public_token'])
					rescue => ex
						BlitlineLogger.log(ex)
					end
				end
			rescue => parex
				BlitlineLogger.log(parex)
			ensure
				run_results.each do |file|
					FileUtils.rm file if file && File.exists?(file)
				end
			end

			return destination_urls
		end


		def load_delta
			return @load_delta
		end

		def function_delta
			return @function_delta
		end

private
		def load_wrapper(pages, dest_folder)
			threads = []
			@load_delta = get_delta do 
				chunk_size = (pages.length / 10).floor
				chunk_size = 1 if chunk_size < 1

				pages.each_slice(chunk_size) do |page_set|
					threads << Thread.new(page_set) do |this_page_set|
					  for page in this_page_set
					  	extname = File.extname(page) == "" ? ".jpg" : File.extname(page)
						dest_filename = File.basename(page, extname) + extname
						dest_path = File.join(dest_folder, dest_filename)
						source_url = page.to_s.gsub("'","%27")
						execution_string = "wget -U 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_6_8) AppleWebKit/537.17 (KHTML, like Gecko) Chrome/24.0.1312.52 Safari/537.17' --no-check-certificate -nv --timeout=60 -t 2 -O '#{dest_path}' '#{source_url}'"
						success = system(execution_string)
					  end
					end
				end

				threads.each { |aThread|  aThread.join }
			end
		end

		def run(urls, max_size = nil)
			files = []
			dest_folder = "/tmp/" + rand(36**12).to_s(36)
			Dir.mkdir(dest_folder)
			begin
				return_results = []
				load_wrapper(urls, dest_folder)
				@function_delta = get_delta do
					files = Dir.glob("#{dest_folder}/*")
					results = add_to_zip_with_max_size(files, max_size)
					return_results = get_zip_file_results(results)
				end
				return return_results
			rescue => ex
				BlitlineLogger.log(ex)
			ensure
				files.each do |file|
					FileUtils.rm file if file && File.exists?(file)
				end
				FileUtils.rm_r dest_folder, :force => true 
			end
		end

		def add_to_zip_with_max_size(files, max_size)
			base_filename = rand(36**8).to_s(36)
			index = 0
			return_path =  "/tmp/#{base_filename}"
			
			if max_size
				dest_zip_path = "/tmp/#{base_filename}_#{index}.zip"
				files.each do |file|
					#file_name = File.basename(file)
					update_zip_with_file(dest_zip_path, file)
					size = File.size(dest_zip_path)
					if size > max_size
						index = index + 1
						dest_zip_path = "/tmp/#{base_filename}_#{index}.zip"
						size = 0				
					end
				end
			else
				dest_zip_path = "/tmp/#{base_filename}_#{index}.zip"
				files.each do |file|
					Zip::Archive.open(dest_zip_path, Zip::CREATE) do |ar|
						ar.add_file(file)
					end
				end
			end

			return { "base_path" => return_path, "count" => index }
		end

		def update_zip_with_file(zip_path, file)
			if !File.exists?(zip_path)
				Zip::Archive.open(zip_path, Zip::CREATE) do |ar|
					ar.add_file(file)
				end
			else 
				Zip::Archive.open(zip_path) do |ar|
					ar.add_file(file)
				end
			end
		end

		def get_zip_file_results(run_results)
			base_path = run_results["base_path"]
			files = Dir.glob("#{base_path}*.zip")
			return files
		end

		def get_delta
			start_time = Time.now.to_f
			yield
			end_time = Time.now.to_f
			return end_time - start_time
		end
	end
end

		
