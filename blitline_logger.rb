require 'awesome_print'

module BlitlineLogger
  def self.log(object)
    if object.kind_of? Exception
      backtrace_array = object.backtrace
      backtrace_array.reject! {|x| x =~ /\.rvm/}
      backtrace_array.unshift(object.message.to_s)
      ap backtrace_array, options = {:color => {:string     => :red}}
    elsif object.kind_of?(Hash)  || object.kind_of?(Array)
      output = ["[" + Time.now.to_s + "] "]
      output << object
      output << "{#{Process.pid}}"
      ap output
    else object.kind_of?(String) 
      puts "[" + Time.now.to_s + "] " + object.inspect + " {#{Process.pid}}"
    end
#    STDOUT.flush
#    STDERR.flush
  end
end
