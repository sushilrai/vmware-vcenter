provider_path = Pathname.new(__FILE__).parent.parent
require File.join(provider_path, 'vcenter')
require 'rbvmomi'
require File.join(provider_path, 'vsanmgmt.api')

MAX_CAPACITY_DISKS = 7

Puppet::Type.type(:vc_vsan_disk_initialize).provide(:vc_vsan_disk_initialize, :parent => Puppet::Provider::Vcenter) do
  @doc = "Initialize VSAN Disk for cluster node"

  def create
    hosts_task_info = {}
    cluster_hosts.each do |host|
      if disk_configured?(host)
        Puppet.debug("Skipping disk Initialization for server #{host.name}")
        next
      else
        hosts_task_info[host.name] = []
        Puppet.debug("Initiating disk intialization for server #{host.name}")
        hosts_task_info[host.name] = initialize_disk(host)
      end
    end

    while !hosts_task_info.keys.empty? do
      hosts_task_info.each do |host_name, task|
        Puppet.debug("Task status for host #{host_name} is #{task.info.state}")
        if task.info.state != "running"
          Puppet.debug("Server %s, Disk initialization status %s" % [host_name, task.info])
          hosts_task_info.delete(host_name)
        end
      end
      sleep(60) unless hosts_task_info.empty?
    end

    # Check if there is any disk left out for the cluster host
    cluster_hosts.each do |host|
      hosts_task_info[host.name] = initialize_spare_disk(host)
    end

    Puppet.debug("Hosts task info %s " % [hosts_task_info])
    hosts_task_info.keys.collect { |x| hosts_task_info.delete(x) if hosts_task_info[x].nil? }

    while !hosts_task_info.keys.empty? do
      hosts_task_info.each do |host_name, task|
        next if task.nil?
        Puppet.debug("Task status for host #{host_name} is #{task.info.state}")
        if task.info.state != "running"
          Puppet.debug("Server %s, Disk re-initialization status %s" % [host_name, task.info])
          hosts_task_info.delete(host_name)
        end
      end
      sleep(60) unless hosts_task_info.empty?
    end

    cluster_hosts.each do |host|
      set_vsan_trace(host)
    end
  end

  def destroy
    if resource[:cleanup_hosts]
      cleanup_hosts_disk_group
    else
      cleanup_cluster_disk_group
    end
  end

  def host_system(host)
    cluster_hosts.find {|x| x.name == host}
  end

  def exists?
    resource[:ensure] != :present
  end

  def datacenter
    @dc ||= vim.serviceInstance.find_datacenter(resource[:datacenter])
  end

  def cluster
    datacenter.find_compute_resource(resource[:cluster])
  end

  private

  def vsan_config_info
    cluster.configurationEx.vsanConfigInfo
  end

  def vsan_hosts
    cluster.configurationEx.vsanHostConfig
  end

  def cluster_hosts
    ( cluster.host || [] )
  end

  def disk_mappings(host)
    diskm = RbVmomi::VIM::VimClusterVsanVcDiskManagementSystem(hsconn, 'vsan-disk-management-system')
    diskm.QueryDiskMappings(:host => host)
  end

  def disk_configured?(host)
    disk_mappings = disk_mappings(host)
    !disk_mappings.empty?
  end

  def hsconn
    conn = RbVmomi::VIM.new(:host => vim.host,
                               :port => 443,
                               :insecure => true,
                               :ns => 'urn:vim25',
                               :ssl => true,
                               :rev => "6.0",
                               :path => '/vsanHealth' )
    conn.cookie = vim.cookie
    conn.debug = vim.debug
    conn
  end

  def initialize_disk(host)
    vsansys = host.configManager.vsanSystem
    vsandisks =  vsansys.QueryDisksForVsan()
    ssd = []
    nonssd = []
    # Sort disk based on the size
    vsandisks.sort! {|x| x.disk.capacity.block }
    vsandisks.each do |vsandisk|
      if vsandisk.disk.displayName.match(/usb/i)
        Puppet.debug("Skipping USB disk %s for server %s " % [vsandisk, host.name])
        next
      end

      if ["inUse", "ineligible"].include?(vsandisk.state)
        Puppet.debug("Skipping in-use or in-eligible disk %s for server %s" % [vsandisk, host.name])
        next
      end

      if vsandisk.disk.displayName =~ /ATA/i && resource[:vsan_disk_group_creation_type].to_s == "hybrid"
        Puppet.debug("Skipping local ATA disk %s for server %s in case of hybrid deployent" % [vsandisk, host.name])
        next
      end

      if vsandisk.disk.ssd
        ssd.push(vsandisk.disk)
      else
        nonssd.push(vsandisk.disk)
      end
    end
    return true if ssd.empty?
    diskspec = RbVmomi::VIM::VimVsanHostDiskMappingCreationSpec.new()
    Puppet.debug("Server: %s SSD Disks: %s" % [host.name, ssd])
    Puppet.debug("Server: %s Non-SSD Disks:  %s" % [host.name, nonssd])

    case resource[:vsan_disk_group_creation_type].to_s
      when "hybrid"
        diskspec.cacheDisks = ssd
        diskspec.capacityDisks = nonssd
        diskspec.creationType = "hybrid"
      when "allFlash"
        ssd.sort! {|x| x.capacity.block }
        disk_sizes = ssd.collect {|x| x.capacity.block }.sort.uniq
        if disk_sizes.size == 1
          ssd.each_slice(8).to_a.each do |ssd_group|
            diskspec.cacheDisks = [ssd_group[0]]
            diskspec.capacityDisks = ssd_group[1..ssd_group.size-1]
          end
        else
          cache_disks = ssd.find_all {|x| x.capacity.block == disk_sizes[0]}
          capacity_disks = ssd.reject {|x| x.capacity.block == disk_sizes[0]}
          diskspec.cacheDisks = cache_disks
          diskspec.capacityDisks = capacity_disks
        end
        diskspec.creationType = "allFlash"
    end
    diskspec.host = host
    diskm = RbVmomi::VIM::VimClusterVsanVcDiskManagementSystem(hsconn, 'vsan-disk-management-system')
    vsan_task = diskm.InitializeDiskMappings(:spec => diskspec)
    Puppet.debug("Server: %s, Disk Spec: %s" % [host.name, diskspec])
    RbVmomi::VIM::Task(vim, vsan_task._ref )
  end

  def initialize_spare_disk(host)
    vsansys = host.configManager.vsanSystem
    vsandisks =  vsansys.QueryDisksForVsan()
    ssd = []
    nonssd = []
    # Sort disk based on the size
    vsandisks.sort! {|x| x.disk.capacity.block }
    vsandisks.each do |vsandisk|
      if vsandisk.disk.displayName.match(/usb/i)
        Puppet.debug("Skipping USB disk %s for server %s " % [vsandisk, host.name])
        next
      end

      if ["inUse", "ineligible"].include?(vsandisk.state)
        Puppet.debug("Skipping in-use or in-eligible disk %s for server %s" % [vsandisk, host.name])
        next
      end

      if vsandisk.disk.displayName =~ /ATA/i && resource[:vsan_disk_group_creation_type].to_s == "hybrid"
        Puppet.debug("Skipping local ATA disk %s for server %s in case of hybrid deployent" % [vsandisk, host.name])
        next
      end

      if vsandisk.disk.ssd
        ssd.push(vsandisk.disk)
      else
        nonssd.push(vsandisk.disk)
      end
    end

    diskspec = RbVmomi::VIM::VimVsanHostDiskMappingCreationSpec.new()
    Puppet.debug("Server: %s SSD Disks: %s" % [host.name, ssd])
    Puppet.debug("Server: %s Non-SSD Disks:  %s" % [host.name, nonssd])

    # If there is no SSD or non-SSD disk then no need to perform anything
    if ssd.empty? && nonssd.empty?
      Puppet.debug("There is no free disk for server %s" % [host.name])
      return nil
    end

    disk_group_capacity = current_disk_group_capacity(host)
    case resource[:vsan_disk_group_creation_type].to_s
      when "hybrid"
        if ssd.empty? && !nonssd.empty?
          if current_disk_group_capacity(host) <= nonssd.size
            diskspec.capacityDisks = nonssd
          else
            # Will try to consume possible disks and leave rest of the disks
            diskspec.capacityDisks = nonssd[0..disk_group_capacity - 1]
          end
        elsif !ssd.empty?
          diskspec.cacheDisks = ssd
          diskspec.capacityDisks = nonssd
        end
        diskspec.creationType = "hybrid"

      when "allFlash"
        # Check the capacity available in existing disk-groups and try to include it
        # If existing capacity is not sufficient then create new disk-group

        if disk_group_capacity <= ssd.size
          diskspec.capacityDisks = ssd
        else
          ssd.sort! {|x| x.capacity.block }
          disk_sizes = ssd.collect {|x| x.capacity.block }.sort.uniq
          if disk_sizes.size == 1
            ssd.each_slice(8).to_a.each do |ssd_group|
              diskspec.cacheDisks = [ssd_group[0]]
              diskspec.capacityDisks = ssd_group[1..ssd_group.size-1]
            end
          else
            cache_disks = ssd.find_all {|x| x.capacity.block == disk_sizes[0]}
            capacity_disks = ssd.reject {|x| x.capacity.block == disk_sizes[0]}
            diskspec.cacheDisks = cache_disks
            diskspec.capacityDisks = capacity_disks
          end
          diskspec.creationType = "allFlash"
        end
    end

    diskspec.host = host
    diskm = RbVmomi::VIM::VimClusterVsanVcDiskManagementSystem(hsconn, 'vsan-disk-management-system')
    vsan_task = diskm.InitializeDiskMappings(:spec => diskspec)
    Puppet.debug("Server: %s, Disk Spec: %s" % [host.name, diskspec])
    RbVmomi::VIM::Task(vim, vsan_task._ref )
  end

  def current_disk_group_capacity(host)
    disk_group_capacity_size = 0
    local_disk_mappings = disk_mappings(host)
    local_disk_mappings.each do |disk_group|
      disk_group_capacity_size += disk_group.mapping.nonSsd.size
    end
    local_disk_mappings.size * 7 - disk_group_capacity_size
  end

  def creation_type(non_ssd)
    non_ssd.size >= 1 ? "hybrid" : "allFlash"
  end


  def cleanup_cluster_disk_group
    cluster_hosts.each do |cluster_host|
      cleanup_disk_group(cluster_host)
    end
  end

  def cleanup_hosts_disk_group
    Puppet.debug("Cleanup hosts : #{resource[:cleanup_hosts]}")
    if resource[:cleanup_hosts].is_a?(String)
      host = host_system(resource[:cleanup_hosts])
      cleanup_disk_group(host)
    else
      resource[:cleanup_hosts].each do |input_host|
        host = host_system(input_host)
        cleanup_disk_group(host)
      end
    end
  end

  def cleanup_disk_group(host)
    vsansys = host.configManager.vsanSystem
    disk_mappings = vsan_query_disk(host)
    unless disk_mappings.empty?
      task_ref = vsansys.RemoveDiskMapping_Task(:mapping => disk_mappings )
      task_ref.wait_for_completion
      raise("Failed to cleanup disk-group for host #{host.name}") unless task_ref.info.state == "success"
    end
  end

  def vsan_query_disk(host)
    vsan_mapping = []
    disk_mappings(host).each do |map|
      vsan_mapping << map.mapping
    end
    vsan_mapping
  end

  def set_vsan_trace(host)
    if resource[:vsan_trace_volume] && !resource[:vsan_trace_volume].empty?
      Puppet.debug("Browsing datastores for setting VSAN trace to #{resource[:vsan_trace_volume]}")
      trace_set = false
      host.datastore.each do |ds|
        next unless ds.info.respond_to?(:name) && ds.info.respond_to?(:url)
        if ds.info.name == resource[:vsan_trace_volume] && ds.info.url && !ds.info.url.empty?
          url = ds.info.url.sub("ds:/","")
          Puppet.info("Setting VSAN trace for #{host.name} to #{ds.info.name} (#{url})")
          begin
            trace_set = host.esxcli.vsan.trace.set({:path => url})
          rescue Exception => ex
            # Don't fail the puppet run if we cannot set VSAN trace, but simply log it
            Puppet.debug("Error #{ex.class}:#{ex.message} on setting VSAN trace to #{url}")
          end
          break
        end
      end
      Puppet.warning("Did not set VSAN traces for #{host.name}") unless trace_set
    end
  end

end
