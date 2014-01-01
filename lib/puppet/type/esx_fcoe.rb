# Copyright (C) 2013 VMware, Inc.
Puppet::Type.newtype(:esx_fcoe) do
  @doc = "Add/Remove FCoE software adapters in vCenter hosts."

  ensurable do
    newvalue(:present) do
      provider.create
    end

    newvalue(:absent) do
      provider.destroy
    end

    defaultto(:present)
  end
  
  newparam(:physical_nic, :namevar => true) do
    desc "Name of the underlying physical Nic that will be associated with the FCoE HBA."
      validate do |value|
          if value.strip.length == 0
              raise ArgumentError, "Invalid underlying physical nic."
          end
        end
  end
  
  newparam(:host) do
      desc "Name or IP address of the host."
      validate do |value|
        if value.strip.length == 0
          raise ArgumentError, "Invalid name or IP address of the host."
        end
      end
   end

end