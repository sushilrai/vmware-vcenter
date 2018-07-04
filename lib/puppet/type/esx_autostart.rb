Puppet::Type.newtype(:esx_autostart) do
  @doc = "Enable / Disable VM auto-state on ESXi server."

  ensurable

  newparam(:name, :namevar => true) do
  end

  newparam(:host) do
  end

  newparam(:datacenter) do
  end

  newparam(:vm_name) do
  end

  newparam(:vm_start_order) do
    defaultto(1)
  end

  newparam(:wait_for_heart_beat) do
    newvalues("yes", "no", "systemDefault")
    defaultto("systemDefault")
  end

  newparam(:start_delay) do
    defaultto(-1)
  end

  newparam(:stop_delay) do
    defaultto(-1)
  end

  newparam(:start_action) do
    newvalues("none", "powerOn")
    defaultto("none")
  end

  newparam(:stop_action) do
    newvalues("none", "systemDefault", "powerOff", "suspend")
    defaultto("none")
  end

  autorequire(:vc_host) do
    self[:host]
  end
end

