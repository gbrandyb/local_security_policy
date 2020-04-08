#encoding: UTF-8
require 'fileutils'

begin
  require "puppet_x/twp/inifile"
  require "puppet_x/lsp/security_policy"
rescue LoadError => detail
  require 'pathname' # JJM WORK_AROUND #14073
  mod = Puppet::Module.find('local_security_policy', Puppet[:environment].to_s)
  if mod
    require File.join(mod.path, 'lib/puppet_x/twp/inifile')
    require File.join(mod.path, 'lib/puppet_x/lsp/security_policy')
  else # received nil, fallback to old style
    module_base = Pathname.new(__FILE__).dirname
    require File.join(module_base, '../../../', 'puppet_x/twp/inifile')
    require File.join(module_base, '../../../', 'puppet_x/lsp/security_policy')
  end
end

Puppet::Type.type(:local_security_policy).provide(:policy) do
  desc 'Puppet type that models the local security policy'

  #
  # TODO Finalize the registry key settings
  # TODO Add in registry value translation (ex: 1=enable 0=disable)
  # TODO Implement self.post_resource_eval (need to collect all resource updates the run secedit to make one call)
  # limit access to windows hosts only
  confine :operatingsystem => :windows
  # limit access to systems with these commands since this is the tools we need
  commands :wmic => 'wmic', :secedit => 'secedit'

  mk_resource_methods

  # export the policy settings to the specified file and return the filename
  def self.export_policy_settings(inffile=nil)
    inffile ||= temp_file
    secedit(['/export', '/cfg', inffile, '/quiet'])
    inffile
  end

  # export and then read the policy settings from a file into a inifile object
  # caches the IniFile object during the puppet run
  def self.read_policy_settings(inffile=nil)
    inffile ||= temp_file
    unless @file_object
      export_policy_settings(inffile)

      # There was an issue with handling multiline registry key strings that contained
      # line feeds (\n). They would cause the ini parser to throw an error.  Need to enclose 
      # the value in double quotes before applying universal newlines in order to flag the parser
      # that it needs to process it as a multiline value.

      #File.open inffile, 'r:IBM437' do |file|
      File.open inffile, 'rb:UTF-16LE' do |file|
        
        # encode as UTF-8 and remove the BOM
        temp_content = file.read.encode('utf-8').gsub("\xEF\xBB\xBF", '')
        # the =7 is the registry type for multiline strings.  all the culprit strings we've found are wrapped in
        # single quotes from secedit for some reason. Need to remove those quotes and wrap the entire value (including leading 7)
        # in double quotes
        multistr_regex = Regexp.new('=7,\'(.*?)\'(\r\n)', Regexp::MULTILINE)
        inffile_content = temp_content.gsub(multistr_regex, '="7,\1"\2')
        #inffile_content.encode('utf-8', :universal_newline => true)
        
        File.write('c:\\windows\\temp\\secedit-processed.inf',inffile_content) # debug
        @file_object ||= PuppetX::IniFile.new(:content => inffile_content)
      end
    end
    @file_object
  end

  # converts any values that might be of a certain type specified in the mapping
  # converts everything to a string
  # returns the value
  def self.fixup_value(value, type)
    value = value.to_s.strip
    case type
      when :quoted_string
        value = "\"#{value}\""
    end
    value
  end

  # exports the current list of policies into a file and then parses that file into
  # provider instances.  If an item is found on the system but not in the lsp_mapping,
  # that policy is not supported only because we cannot match the description
  # furthermore, if a policy is in the mapping but not in the system we would consider
  # that resource absent
  def self.instances
    settings = []
    inf = read_policy_settings
    # need to find the policy, section_header, policy_setting, policy_value and reg_type
    inf.each do |section, parameter_name, parameter_value|
      next if section == 'Unicode'
      next if section == 'Version'
      begin
        ensure_value = parameter_value.nil? ? :absent : :present
        policy_desc, policy_values = SecurityPolicy.find_mapping_from_policy_name(parameter_name)
        policy_hash = {
            :name => policy_desc,
            :ensure => ensure_value,
            :policy_type => section ,
            :policy_setting => parameter_name,
            :policy_value => fixup_value(parameter_value, policy_values[:data_type])
        }
        inst = new(policy_hash)
        settings << inst
      rescue KeyError => e
        Puppet.debug e.message
      end
    end
    settings
  end

  # the flush method will be the last method called after applying all the other
  # properties, by default nothing will be enabled or disabled unless the disable/enable are set to true
  # if we ever move to a point were we can write all the settings via one big config file we
  # would want to do that here.
  def flush
    begin
      write_policy_to_system(resource.to_hash)
    rescue KeyError => e
      Puppet.debug e.message
      # send helpful debug message to user here
    end
    @property_hash = resource.to_hash
  end

  def initialize(value={})
    super(value)
    @property_flush = {}
  end

  # create the resource and convert any user supplied values to computer terms
  def create
    # do everything in flush method
  end

  # this is currently not implemented correctly on purpose until we can figure out how to safely remove
  def destroy
    @property_hash[:ensure] = :absent
    #Destroy not an option for now.  LSP Settings should be set to something.
    # we need some default destroy values in the mappings so we know ahead of time what to put unless the user supplies
    # but this would just ensure a value the setting should go back to
  end

  def self.prefetch(resources)
    policies = instances
    resources.keys.each do |name|
      if found_pol = policies.find { |pol| pol.name == name }
        resources[name].provider = found_pol
      end
    end
  end

  def exists?
    @property_hash[:ensure] == :present
  end

  # gets the property hash from the provider
  def to_hash
    instance_variable_get('@property_hash')
  end

  # required for easier mocking, this could be a Tempfile too
  def self.temp_file
    'c:\\windows\\temp\\secedit.inf'
  end

  def temp_file
    'c:\\windows\\temp\\secedit.inf'
  end

  # writes out one policy at a time using the InfFile Class and secedit
  def write_policy_to_system(policy_hash)
    time = Time.now
    time = time.strftime("%Y%m%d%H%M%S")
    infout = "c:\\windows\\temp\\infimport-#{time}.inf"
    sdbout = "c:\\windows\\temp\\sdbimport-#{time}.inf"
    #logout = "c:\\windows\\temp\\logout-#{time}.inf"
    status = nil
    begin
      # read the system state into the inifile object for easy variable setting
      inf = PuppetX::IniFile.new
      # these sections need to be here by default
      inf["Version"] = {"signature"=>"$CHICAGO$", "Revision"=>1}
      inf["Unicode"] = {"Unicode"=>"yes"}
      section = policy_hash[:policy_type]
      section_value = {policy_hash[:policy_setting] => policy_hash[:policy_value]}
      # we can utilize the IniFile class to write out the data in ini format
      inf[section] = section_value
      inf.write(:filename => infout, :encoding => 'utf-8')
      secedit(['/configure', '/db', sdbout, '/cfg',infout])
    ensure
      #FileUtils.rm_f(temp_file)
      FileUtils.rm_f(infout)
      FileUtils.rm_f(sdbout)
      #FileUtils.rm_f(logout)
    end
  end
end
