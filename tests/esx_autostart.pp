transport { 'vcenter':
  username => "administrator@vsphere.local",
  password => "P@ssw0rd",
  server   => "100.68.97.72",
  options  => {"insecure" => true},
  provider => "device_file"
}

esx_autostart { "100.68.97.99":
  ensure    => present,
  host => "100.68.97.99",
  datacenter => "aer1dc1",
  vm_name => "svm-aer1r740xd-4",
  transport => Transport['vcenter']
}

