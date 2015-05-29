# -*- encoding : utf-8 -*-
require "shell_utils"
require "sets_sync"

require 'fileutils'
require 'pathname'

class Grader
  include ShellUtils

  LANG_TO_COMPILER = {}

  class << self
    def with_stdout_and_stderr(new_stdout, new_stderr, &block)
      old_stdout, old_stderr = $stdout.dup, $stderr.dup
      STDOUT.reopen(new_stdout)
      STDERR.reopen(new_stderr)

      yield
    ensure
      STDOUT.reopen(old_stdout)
      STDERR.reopen(old_stderr)
    end
  end

  def initialize
    @config = get_config
  end

  def run
    running = true
    puts "Ready to grade"

    while running do
      ["INT", "TERM"].each do |signal|
        Signal.trap(signal) do
          puts "Stopping..."
          running = false
        end
      end

      if !process_one_run
        sleep 1
      end
    end
  end

  private

  attr_reader :config

  def update_checker(run)
    Dir.chdir(File.join(@config[:files_root], @config[:sync_to], run.task_id.to_s)) do
      File.open("grader.log", "w") do |f|
        data = ActiveSupport::JSON.decode(run.data)
        if data["source_code"].empty?
          run.task.update_attribute(:checker, nil)
          run.update_attributes(status: Run::STATUS_SUCCESS,
                                message: "Default checker set")
        else
          if compile(data["source_code"], data["lang"], "checker")
            run.update_attributes(status: Run::STATUS_SUCCESS,
                                  message: "New checker set")
            run.task.update_attribute(:checker, data["lang"])
          else
            run.update_attributes(status: Run::STATUS_CE,
                                  message: "Compilation error",
                                  log: File.read("grader.log"))
          end
        end
      end
    end
  end

  def process_task_update(run)
    puts 'Update task run: %d' % run.id
    from = File.join(run.user.file_path, run.data.to_s, '*')
    to = File.join(@config[:files_root], @config[:sync_to], run.task_id.to_s)
    FileUtils.mkdir_p(to)
    puts "Removing %s" % File.join(to, '*')
    FileUtils.rm(Dir.glob(File.join(to, '*')))
    puts "Syncing tests from #{from} to #{to}"
    sync_command = @config[:sync] % [from, to]
    if verbose_system sync_command
      run.update_attributes(status: Run::STATUS_SUCCESS, message: "Done")
    else
      run.update_attributes(status: Run::STATUS_ERROR, message: $?)
    end
  end

  def grade(run)
    puts 'Grade task run: %d' % run.id

    run_dir = prepare_run_directory(run)

    execute_run(run, run_dir)

    # Remove the directory after the execution.
    # FileUtils.rm_rf(run_dir)
  end

  def prepare_run_directory(run)
    run_dir = File.join(@config[:files_root], @config[:runs_dir], run.id.to_s)
    FileUtils.mkdir_p(run_dir)
    FileUtils.rm(Dir.glob(File.join(run_dir, '*')))
    run_dir
  end

  def execute_run(run, run_dir)
    data = ActiveSupport::JSON.decode(run.data)
    puts "Data received for run #{run.id}: #{data}"

    Dir.chdir(run_dir) do
      File.open("grader.log", "w") do |f|
        f.sync = true
        self.class.with_stdout_and_stderr(f, f) do
          puts "Running process..."
          run.update_attributes(status: Run::STATUS_RUNNING,
                                message: "Running")
          if supported_language?(data["lang"])
            if !compile(data["source_code"], data["lang"])
              run.update_attributes(status: Run::STATUS_CE,
                message: 'Compilation error',
                log: File.read("grader.log"))
            else
              input_file_pat = File.join(@config[:files_root], @config[:sync_to], run.task_id.to_s, 'input.*.txt')
              input_files = Dir.glob(input_file_pat).sort
              output_file_pat = File.join(@config[:files_root], @config[:sync_to], run.task_id.to_s, 'solve.*.txt')
              output_files = Dir.glob(output_file_pat).sort

              if run.task.task_type == Task::TASK_TYPE_PYUNIT
                File.open("wrapper_code.py", "w") do |f|
                  f.write(run.task.wrapper_code)
                end
              end

              puts "Running tests..."
              results = run_tests(run, input_files, output_files, data["lang"])

              run.update_attributes(status: Run::STATUS_SUCCESS,
                message: results,
                log: File.read("grader.log"))
            end
          else
            run.update_attributes(status: Run::STATUS_ERROR,
              message: 'Unknown language',
              log: File.read("grader.log"))
          end
        end
      end
    end
  end

  def supported_language? lang
    ['c++', 'java', 'python'].include?(lang)
  end

  def get_config
    grader_conf = YAML.load_file(Rails.root.join("config/grader.yml"))
    puts "Reading configuration for env #{Rails.env}"
    if !grader_conf[Rails.env]
      puts "Cannot find configuration for #{Rails.env}. Check your config/grader.yml"
      exit 1
    end
    grader_conf[Rails.env].with_indifferent_access
  end

  def process_one_run
    found = false

    if run = Run.pending.earliest_first.first
      if run.task.nil?
        run.update_attributes(status: Run::STATUS_ERROR,
          message: "Run with an invalid task requested. Skipped.")
      else
        case run.code
        when Run::CODE_UPDATE_TASK
          found = true
          process_task_update(run)
        when Run::CODE_RUN_TASK
          found = true
          grade(run)
        when Run::CODE_UPDATE_CHECKER
          found = true
          update_checker(run)
        end
      end
    end

    found
  end

  def compile(source_code, language, file_name = "program")
    puts "==== GRADER ==== Start compiling ===="
    if language == 'c++'
      # puts "Create file " + ("%.cpp" % [file_name])
      File.open("%s.cpp" % [file_name], "w") do |f|
        f.write(source_code)
      end

      puts "Compiling C++ ..."
      # verbose_system "g++ program.cpp -o program -O2 -static -lm -x c++"
      verbose_system @config[:compile_cpp] % [file_name, file_name]
    elsif language == 'java'
      File.open("%s.java" % [file_name], "w") do |f|
        f.write(source_code)
      end

      puts "Compiling Java ..."
      # verbose_system "g++ program.cpp -o program -O2 -static -lm -x c++"
      verbose_system @config[:compile_java] % [file_name, file_name]
    elsif language == 'python'
      # Python is not compiled, just the source file is created here.
      File.open("%s.py" % [file_name], "w") do |f|
        f.write(source_code)
      end
      return true
    end

    puts "==== GRADER ==== End compiling ===="

    if $?.nil?
      return false
    else
      return $?.exitstatus == 0
    end
  end

  def run_tests(run, input_files, output_files, language)
    if input_files.empty? || output_files.empty?
      return "No tests"
    end

    # for each test, run the program
    input_files.zip(output_files).map { |input_file, answer_file|
      base_name = Pathname.new(input_file).basename
      if language == 'c++'
        run_one_test(run, input_file, answer_file, "cpp")
      elsif language == 'java'
        run_one_test(run, input_file, answer_file, "java")
      elsif language == 'python'
        run_one_test(run, input_file, answer_file, "python")
      end
    }.join(" ")
  end

  def run_one_test(run, input_file, answer_file, config_lang)
    base_name = Pathname.new(input_file).basename
    verbose_system(@config["init_#{config_lang}".to_sym] % [input_file])
    # verbose_system(@config["run_#{config_lang}".to_sym] % [base_name])

    runner = Pathname.new(File.join(File.dirname(__FILE__), @config["runner_#{config_lang}"])).realpath.to_s

    if run.task.task_type == Task::TASK_TYPE_PYUNIT
        verbose_system "#{runner} --time #{run.max_time_ms} "\
                       "--mem #{run.max_memory_kb} --procs 1 "\
                       "--python #{@config[:python_exec]} "\
                       "--sandbox-user #{@config[:python_sandbox_user]} "\
                       "-i #{base_name} -o output "\
                       "-- ./wrapper_code.py ./program.py"
    else
      if config_lang == 'python'
        verbose_system "#{runner} --time #{run.max_time_ms} "\
                       "--mem #{run.max_memory_kb} --procs 1 "\
                       "--python #{@config[:python_exec]} "\
                       "--sandbox-user #{@config[:python_sandbox_user]} "\
                       "-i #{base_name} -o output "\
                       "-- ./program.py"
      else
        verbose_system "#{runner} --time #{run.max_time_ms} "\
                       "--mem #{run.max_memory_kb} --procs 1 "\
                       "-i #{base_name} -o output -- ./program"
      end
    end
    result = "n/a"
    run_status = $?.exitstatus

    puts "==== GRADER ==== Start cleanup"
    dir_name = Pathname.new(input_file).dirname
    verbose_system(@config["cleanup_#{config_lang}".to_sym])
    puts "==== GRADER ==== End cleanup"

    case run_status
      when 9
        result = "tl"
      when 127
        result = "ml"
      when 0
        result = check_output(run, answer_file, input_file)
      else
        result = "re"
    end

    return result
  end

  def check_output(run, answer_file, input_file)
    puts "Checking output..."
    if run.task.checker
      checker = File.join(@config[:files_root], @config[:sync_to], run.task_id.to_s, 'checker')
      verbose_system "#{checker} #{input_file} #{answer_file} output"
    else
      checker = "ruby " + Rails.root.join("lib/execs/diff.rb").to_s
      verbose_system "#{checker} #{answer_file} output"
    end

    if $?.exitstatus != 0
      "wa"
    else
      "ok"
    end

  end
end
