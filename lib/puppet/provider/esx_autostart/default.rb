provider_path = Pathname.new(__FILE__).parent.parent
require File.join(provider_path, 'vcenter')
require 'resolv'

Puppet::Type.type(:esx_autostart).provide(:esx_alarm, :parent => Puppet::Provider::Vcenter) do
  @doc = "Manages ESXi VM auto-start capability."

  def exists?
    #host.configManager.autoStartManager.config.defaults.enabled
    false
  end

  def create
    spec = host.configManager.autoStartManager.config

    # Enable the auto-start manager
    defaultSettings = spec.defaults
    defaultSettings.enabled = true
    spec.defaults = defaultSettings

    # Update the Auto-start manager settings
    host.configManager.autoStartManager.ReconfigureAutostart(:spec => spec)
    if resource[:vm_name]
      # Get the autoStartManager for configuration
      autoStartManager = host.configManager.autoStartManager

      power_info = {}
      # Configuring the parameters
      power_info[:key] = vm
      power_info[:startOrder] = resource[:vm_start_order]
      power_info[:startAction] = resource[:start_action].to_s
      power_info[:stopAction] = resource[:stop_action].to_s
      power_info[:waitForHeartbeat] = resource[:wait_for_heart_beat].to_s
      power_info[:startDelay] = resource[:start_delay]
      power_info[:stopDelay] = resource[:stop_delay]

      # Get the autoStartManagerConfig data object
      spec = autoStartManager.config
      spec.powerInfo = [power_info]

      # Update the Auto-start manager settings
      require 'pry'
      binding.pry
      autoStartManager.ReconfigureAutostart(:spec => spec)
    end
  end

  def destroy
    Puppet.debug("inside destroy block")
    spec = host.configManager.autoStartManager.config
    defaultSettings = spec.defaults
    defaultSettings.enabled = false
    spec.defaults = defaultSettings
    host.configManager.autoStartManager.ReconfigureAutostart(:spec => spec)
  end

  def host
    @host ||= vim.searchIndex.FindByDnsName(:datacenter => datacenter , :dnsName => resource[:host], :vmSearch => false) or raise(Puppet::Error, "Unable to find the host '#{resource[:host]}")
  end

  def datacenter
    @datacenter ||= vim.serviceInstance.find_datacenter(resource[:datacenter]) or raise(Puppet::Error, "datacenter '#{resource[:datacenter]}' not found.")
  end

  def vm
    @vm ||= datacenter.vmFolder.childEntity.grep(RbVmomi::VIM::VirtualMachine).find {|v| v.name == resource[:vm_name]}
  end
end

