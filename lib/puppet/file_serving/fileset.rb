require 'find'
require 'puppet/file_serving'
require 'puppet/file_serving/metadata'

# Operate recursively on a path, returning a set of file paths.
class Puppet::FileServing::Fileset
  attr_reader :path, :ignore, :links
  attr_accessor :recurse, :recurselimit, :checksum_type

  # Produce a hash of files, with merged so that earlier files
  # with the same postfix win.  E.g., /dir1/subfile beats /dir2/subfile.
  # It's a hash because we need to know the relative path of each file,
  # and the base directory.
  #   This will probably only ever be used for searching for plugins.
  def self.merge(*filesets)
    result = {}

    filesets.each do |fileset|
      fileset.files.each do |file|
        result[file] ||= fileset.path
      end
    end

    result
  end

  def initialize(path, options = {})
    if Puppet.features.microsoft_windows?
      # REMIND: UNC path
      path = path.chomp(File::SEPARATOR) unless path =~ /^[A-Za-z]:\/$/
    else
      path = path.chomp(File::SEPARATOR) unless path == File::SEPARATOR
    end
    raise ArgumentError.new("Fileset paths must be fully qualified: #{path}") unless Puppet::Util.absolute_path?(path)

    @path = path

    # Set our defaults.
    @ignore = []
    @links = :manage
    @recurse = false
    @recurselimit = :infinite

    if options.is_a?(Puppet::Indirector::Request)
      initialize_from_request(options)
    else
      initialize_from_hash(options)
    end

    raise ArgumentError.new("Fileset paths must exist") unless stat = stat(path)
    raise ArgumentError.new("Fileset recurse parameter must not be a number anymore, please use recurselimit") if @recurse.is_a?(Integer)
  end

  # Return a list of all files in our fileset.  This is different from the
  # normal definition of find in that we support specific levels
  # of recursion, which means we need to know when we're going another
  # level deep, which Find doesn't do.
  def files
    files = perform_recursion

    # Now strip off the leading path, so each file becomes relative, and remove
    # any slashes that might end up at the beginning of the path.
    result = files.collect { |file| file.sub(%r{^#{Regexp.escape(@path)}/*}, '') }

    # And add the path itself.
    result.unshift(".")

    result
  end

  def ignore=(values)
    values = [values] unless values.is_a?(Array)
    @ignore = values
  end

  def links=(links)
    links = links.to_sym
    raise(ArgumentError, "Invalid :links value '#{links}'") unless [:manage, :follow].include?(links)
    @links = links
    @stat_method = links == :manage ? :lstat : :stat
  end

  private

  Traversal = Struct.new(:depth, :path)

  def initialize_from_hash(options)
    options.each do |option, value|
      method = option.to_s + "="
      begin
        send(method, value)
      rescue NoMethodError
        raise ArgumentError, "Invalid option '#{option}'"
      end
    end
  end

  def initialize_from_request(request)
    [:links, :ignore, :recurse, :recurselimit, :checksum_type].each do |param|
      if request.options.include?(param) # use 'include?' so the values can be false
        value = request.options[param]
      elsif request.options.include?(param.to_s)
        value = request.options[param.to_s]
      end
      next if value.nil?
      value = true if value == "true"
      value = false if value == "false"
      value = Integer(value) if value.is_a?(String) and value =~ /^\d+$/
      send(param.to_s + "=", value)
    end
  end

  # Pull the recursion logic into one place.  It's moderately hairy, and this
  # allows us to keep the hairiness apart from what we do with the files.
  def perform_recursion
    # Start out with just our base directory.
    current_dirs = [Traversal.new(0, @path)]

    result = []

    while traversal = current_dirs.shift
      dir_path = traversal.path
      next unless stat = stat(dir_path)
      next unless stat.directory?

      Dir.entries(dir_path).each do |file_path|
        next if [".", ".."].include?(file_path)

        # Note that this also causes matching directories not
        # to be recursed into.
        next if ignore?(file_path)

        path = File.join(dir_path, file_path)

        if recurse?(traversal.depth + 1)
          result << path

          current_dirs << Traversal.new(traversal.depth + 1, path)
        end
      end
    end

    result
  end

  # Stat a given file, using the links-appropriate method.
  def stat(path)
    @stat_method ||= self.links == :manage ? :lstat : :stat

    begin
      return File.send(@stat_method, path)
    rescue
      # If this happens, it is almost surely because we're
      # trying to manage a link to a file that does not exist.
      return nil
    end
  end

  # Should we ignore this path?
  def ignore?(path)
    return false if @ignore == [nil]

    # 'detect' normally returns the found result, whereas we just want true/false.
    ! @ignore.detect { |pattern| File.fnmatch?(pattern, path) }.nil?
  end

  # Should we recurse further?  This is basically a single
  # place for all of the logic around recursion.
  def recurse?(depth)
    # recurse if told to, and infinite recursion or current depth not at the limit
    self.recurse and (self.recurselimit == :infinite or depth <= self.recurselimit)
  end
end
