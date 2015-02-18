#!/usr/bin/env ruby
# encoding: UTF-8

require 'pp'   
require 'json'

$stdout.sync = true   

config_file = '/etc/simple_tiles.cfg'
configuration = JSON.parse(File.read(config_file), :symbolize_names => true)

if configuration[:logfile] == 'null' or configuration[:logfile] == '/dev/null' or configuration[:logfile] == 'console' then
    puts "Nothing to do..."
    exit(0)
end

logfile      = configuration[:logfile]
log_dir      = File.dirname(logfile)
log_basename = File.basename(logfile) + "."

Dir.foreach(log_dir) do |filename|
    next if filename == '.' or filename == '..'
    next unless filename.start_with?(log_basename)

    current_path = File.join(log_dir, filename)

    # Delete logfiles older than 7 days
    if (Time.now - File.mtime(current_path)) > (7 * 86400)
        File.delete(current_path)
        next
    end

    next if filename.end_with?(".gz")

    system("/bin/gzip -f #{current_path}")
end
