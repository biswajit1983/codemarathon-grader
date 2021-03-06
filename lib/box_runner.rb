#!/usr/bin/env ruby
# Runs a process with some resource limitations
# Spacial status codes:
# 127 - memory limit
# 9 - time limit
require File.dirname(__FILE__) + "/runner_args.rb"

opt = Options.new

box = File.join(File.dirname(__FILE__), "../sandboxes/box-#{RUBY_PLATFORM}")
%x{#{box} -T -t #{opt.timelimit / 1000.0} -w #{opt.timelimit / 100.0} -m #{opt.mem} -M stat -a 0 -i #{opt.input} -o #{opt.output} -- #{opt.cmd}}
status = File.read("stat").lines.inject({}) { |h, l| k, v = l.strip.split(":"); h[k] = v; h; }
$stderr.puts "Used time: #{status["time"]}"

memory_limit = status["status"] == "SG"
File.open(opt.output, "r") do |f|
  f.each_line do |line|
    memory_limit ||= line =~ /Out of memory/
    break;
  end
end

if memory_limit
  $stderr.puts "Used mem: #{opt.mem}"
else
  $stderr.puts "Used mem: #{status["mem"]}" 
end

exit 9 if status["status"] == "TO"
exit 127 if memory_limit
exit $?.exitstatus
