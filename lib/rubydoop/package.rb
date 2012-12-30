# encoding: utf-8

require 'bundler'
require 'open-uri'
require 'ant'
require 'fileutils'
require 'set'
require 'tmpdir'


module Rubydoop
  # Utility for making a job JAR that works with Hadoop.
  #
  # @example Easy to use from Rake
  #     task :package do
  #       Rudoop::Package.create!
  #     end
  class Package
    # A package has sane defaults that works in most situations, but almost 
    # everything can be changed.
    #
    # If you have extra JAR files that you need to make available for your job
    # you can specify them with the `:lib_jars` option.
    #
    # @param [Hash] options
    # @option options [String]        :project_base_dir The project's base dir, defaults to the current directory (the assumption is that Package will be used from a Rake task)
    # @option options [String]        :project_name     The name of the JAR file (minus .jar), defaults to the directory name of the `:project_base_dir`
    # @option options [String]        :build_dir        The directory to put the final JAR into, defaults to `:project_base_dir + '/build'`
    # @option options [Array<String>] :gem_groups       All gems from these Gemfile groups will be included, defaults to `[:default]` (the top-level group of a Gemfile)
    # @option options [Array<String>] :lib_jars         Paths to extra JAR files to include in the JAR's lib directory (where they will be on the classpath when the job is run)
    # @option options [String]        :jruby_version    The JRuby version to package, defaults to `JRUBY_VERSION`
    # @option options [String]        :jruby_jar_path   The path to a local copy of `jruby-complete.jar`, defaults to downloading and caching a version defined by `:jruby_version`
    def initialize(options={})
      @options = default_options.merge(options)
      @options[:project_name] ||= File.basename(@options[:project_base_dir])
      @options[:build_dir] ||= File.join(@options[:project_base_dir], 'build')
      @options[:jruby_jar_path] ||= File.join(@options[:build_dir], "jruby-complete-#{@options[:jruby_version]}.jar")
      @options[:jar_path] ||= File.join(@options[:build_dir], "#{@options[:project_name]}.jar")
    end

    # Create the JAR package, see {Package#initialize} for configuration options.
    #
    # On the first run a complete JRuby runtime JAR will be downloaded 
    # (`jruby-complete.jar`) and locally cached, but if you already have a
    # copy in a local Ivy or Maven repository that will be used instead.
    def create!
      create_directories!
      fetch_jruby!
      build_jar!
    end

    # A shortcut for `Package.new(options).create!`.
    def self.create!(options={})
      new(options).create!
    end

    def respond_to?(name)
      @options.key?(name) or super
    end

    def method_missing(name, *args)
      @options[name] or super
    end

    private

    def default_options
      defaults = {
        :main_class => 'rubydoop.RubydoopJobRunner',
        :rubydoop_base_dir => File.expand_path('../../..', __FILE__),
        :project_base_dir => Dir.getwd,
        :gem_groups => [:default],
        :lib_jars => [],
        :jruby_version => JRUBY_VERSION
      }
    end

    def create_directories!
      FileUtils.mkdir_p(@options[:build_dir])
    end

    def fetch_jruby!
      return if File.exists?(@options[:jruby_jar_path])

      local_maven_path = File.expand_path("~/.m2/repository/org/jruby/jruby-complete/#{@options[:jruby_version]}/jruby-complete-#{@options[:jruby_version]}.jar")
      local_ivy_path = File.expand_path("~/.ivy2/cache/org.jruby/jruby-complete/jars/jruby-complete-#{@options[:jruby_version]}.jar")
      remote_maven_url = "http://central.maven.org/maven2/org/jruby/jruby-complete/#{@options[:jruby_version]}/jruby-complete-#{@options[:jruby_version]}.jar"

      if File.exists?(local_maven_path)
        @options[:jruby_jar_path] = local_maven_path
      elsif File.exists?(local_ivy_path)
        @options[:jruby_jar_path] = local_ivy_path
      else
        jruby_complete_bytes = open(remote_maven_url).read
        File.open(@options[:jruby_jar_path], 'wb') do |io|
          io.write(jruby_complete_bytes)
        end
      end
    end

    def build_jar!
      @tmpdir =  Dir.mktmpdir('rubydoop')
      # the ant block is instance_exec'ed so instance variables and methods are not in scope
      options = @options
      bundled_gems = load_gem_require_paths
      bundled_gem_files = load_gem_files
      lib_jars = [options[:jruby_jar_path], *options[:lib_jars]]
      ant :output_level => 1 do
        jar :destfile => options[:jar_path], :duplicate => :preserve do
          manifest { attribute :name => 'Main-Class', :value => options[:main_class] }
          zipfileset :src => "#{options[:rubydoop_base_dir]}/lib/rubydoop.jar"
          fileset :dir => "#{options[:rubydoop_base_dir]}/lib", :includes => '**/*.rb', :excludes => '*.jar'
          bundled_gems.each { |path| zipfileset :dir => path[0], :includes => "#{path[1]}/", :prefix => 'classes' }
          bundled_gem_files.each { |path| zipfileset :dir => path[0], :includes => "#{path[1]}", :prefix => 'classes' }
          zipfileset :dir => "#{options[:project_base_dir]}/lib", :prefix => 'classes'
          lib_jars.each { |extra_jar| zipfileset :dir => File.dirname(extra_jar), :includes => File.basename(extra_jar),
              :prefix => 'lib' }
        end
      end
    ensure
      FileUtils.rm_rf(@tmpdir)
    end

    def load_gem_require_paths
      Bundler.definition.specs_for(@options[:gem_groups]).flat_map do |spec|
        if spec.full_name =~ /^jruby-openssl-\d+/
          Dir.chdir(@tmpdir) do
            repackage_openssl(spec)
          end
        elsif spec.full_name !~ /^(?:bundler|rubydoop)-\d+/
          spec.require_paths.map do |rp|
            [spec.full_gem_path, rp]
          end
        else
          []
        end
      end
    end

    def load_gem_files
      Bundler.definition.specs_for(@options[:gem_groups]).flat_map do |spec|
        if spec.full_name !~ /^(?:bundler|rubydoop|jruby-openssl)-\d+/
          spec.files.select {|f| f =~ /\.rb$/}.map do |f|
            [spec.full_gem_path, f]
          end
        else
          []
        end
      end
    end

    def repackage_openssl(spec)
      FileUtils.cp_r(spec.full_gem_path, 'jruby-openssl')
      FileUtils.mv('jruby-openssl/lib/shared', 'jruby-openssl/new_lib')
      FileUtils.mv('jruby-openssl/lib/1.8', 'jruby-openssl/new_lib/openssl/1.8')
      FileUtils.mv('jruby-openssl/lib/1.9', 'jruby-openssl/new_lib/openssl/1.9')
      main_file = File.read('jruby-openssl/new_lib/openssl.rb')
      main_file.gsub!('../1.8', 'openssl/1.8')
      main_file.gsub!('../1.9', 'openssl/1.9')
      File.open('jruby-openssl/new_lib/openssl.rb', 'w') { |io| io.write(main_file) }
      FileUtils.rm_r('jruby-openssl/lib')
      FileUtils.mv('jruby-openssl/new_lib', 'jruby-openssl/lib')
      [["#{@tmpdir}/jruby-openssl", "lib"]]
    end
  end
end
