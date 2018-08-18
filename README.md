# Deploying a NVIDIA GPU in OpenStack Queens via TripleO

Instructions for configuring OpenStack 13 director to deploy instances with PCI Passthrough enabled to support Nvidia GPUs.

## Basic workflow

1. Deploy undercloud and import overcloud servers to Ironic
2. Enable IOMMU in server BIOS to support PCI passthrough
3. Deploy overcloud with templates that configure: iommu in grub, pci device aliases, pci device whitelist, and PciPassthrough filter enabled in nova.conf
4. Customize RHEL 7.5 image with kernel headers/devel and gcc
5. Create custom Nova flavor with PCI device alias
6. Configure cloud-init to install cuda at instance boot time
7. Launch instance from flavor + cloud-init + image via Heat
8. Run sample codes


## Create TripleO environment files

Create TripleO environment files to configure nova.conf on the overcloud nodes running nova-compute and nova-scheduler.


```
    $ cat templates/environments/20-compute-params.yaml
    parameter_defaults:


      NovaPCIPassthrough:
            - vendor_id: "10de"
              product_id: "13f2"


    $ cat templates/environments/20-controller-params.yaml
    parameter_defaults:


      NovaSchedulerDefaultFilters: ['AvailabilityZoneFilter','RamFilter','ComputeFilter','ComputeCapabilitiesFilter','ImagePropertiesFilter','ServerGroupAntiAffinityFilter','ServerGroupAffinityFilter', 'PciPassthroughFilter', 'NUMATopologyFilter', 'AggregateInstanceExtraSpecsFilter']


      ControllerExtraConfig:
        nova::pci::aliases:
          -  name: a1
             product_id: '13f2'
             vendor_id: '10de'
          -  name: a2
             product_id: '13f2'
             vendor_id: '10de'
```

In the above example, the controller node aliases two M60 cards with the names a1 and a2. Depending on the flavor, either or both cards can be assigned to an instance.


The environment files require the vendor ID and product ID for each passthrough device type. Find these with lspci on the physical server with the PCI cards.

```
    # lspci -nn | grep -i nvidia
    3d:00.0 VGA compatible controller [0300]: NVIDIA Corporation GM204GL [Tesla M60] [10de:13f2] (rev a1)
    3e:00.0 VGA compatible controller [0300]: NVIDIA Corporation GM204GL [Tesla M60] [10de:13f2] (rev a1)
```

The vendor ID is the first 4 digit hexadecimal number following the device name. The product ID is the second.

The pciutils package installs lspci.


iommu must also be enabled at boot time on the compute nodes. First include the host-config-and-reboot.yaml environment file to the deploy command.

```
    $ grep host-config scripts/overcloud-deploy.sh
    -e /usr/share/openstack-tripleo-heat-templates/environments/host-config-and-reboot.yaml \
```

Next, add KernelArgs to the compute parameters YAML file.

```
    $ cat templates/environments/20-compute-params.yml
    parameter_defaults:

      NovaPCIPassthrough:
            - vendor_id: "10de"
              product_id: "13f2"

      ComputeBParameters:
        KernelArgs: "intel_iommu=on iommu=pt"
```

The kernel arguments will be added to the Compute nodes at deploy time. This can be verified after deployment by checking /proc/cmdline on the compute node:

```
    $ ssh -l heat-admin 172.16.0.31 cat /proc/cmdline
    BOOT_IMAGE=/boot/vmlinuz-3.10.0-862.6.3.el7.x86_64 root=UUID=7aa9d695-b9c7-416f-baf7-7e8f89c1a3bc ro console=tty0 console=ttyS0,115200n8 crashkernel=auto rhgb quiet intel_iommu=on iommu=pt
```

Direct  IO virtualization must also be enabled in the server BIOS. This feature  can be called VT-d, VT-Direct, or Global SR_IOV Enable.


## Customize the RHEL 7.5 image

Download the RHEL 7.5 KVM guest image and customize it. This image will be used to launch the guest instance.

```
    $ virt-customize --selinux-relabel -a images/rhel75u1-gpu.qcow2 --root-password password:redhat
    $ virt-customize --selinux-relabel -a images/rhel75u1-gpu.qcow2 --run-command 'subscription-manager register --username=REDACTED --password=REDACTED'
    $ virt-customize --selinux-relabel -a images/rhel75u1-gpu.qcow2 --run-command 'subscription-manager attach --pool=REDACTED'
    $ virt-customize --selinux-relabel -a images/rhel75u1-gpu.qcow2 --run-command 'subscription-manager repos --disable=\*'
    $ virt-customize --selinux-relabel -a images/rhel75u1-gpu.qcow2 --run-command 'subscription-manager repos --enable=rhel-7-server-rpms --enable=rhel-7-server-extras-rpms --enable=rhel-7-server-rh-common-rpms --enable=rhel-7-server-optional-rpms'
    $ virt-customize --selinux-relabel -a images/rhel75u1-gpu.qcow2 --run-command 'yum install -y kernel-devel-$(uname -r) kernel-headers-$(uname -r) gcc pciutils wget'
    $ virt-customize --selinux-relabel -a images/rhel75u1-gpu.qcow2 --update
```

In this example we set a root password, register the server to CDN, subscribe only to the rhel-7-server-rpms, rhel-7-server-extras-rpms, rhel-7-server-rh-common-rpms, and rhel-7-server-optional-rpms channels. We also install the kernel-devel and kernel-headers packages along with gcc. These packages are required to build a kernel specific version of the Nvidia driver. Finally, we update the installed packages to the latest versions available from CDN.

After the image has been customized, we upload the image to Glance in the overcloud:

```
    $ source ~/overcloudrc
    $ openstack image create --disk-format qcow2 --container-format bare --public --file images/rhel75u1-gpu.qcow2 rhel75u1-gpu
```


## Deploy test Heat stack

The github repository includes Heat templates that:

1. Creates a flavor tagged with the PCI alias
2. Creates a test tenant and network with external access via floating IP addresses
3. Launches an instance from the image and flavor
4. Associated a floating IP and keypair with the instance
5. Installs the Cuda drivers and sample code on the instance via  Heat softwareConfig script

Run the Heat stack gpu_admin in the overcloud admin tenant to create the project, user, flavor, and networks.

```
    $ source ~/overcloudrc
    $ openstack stack create -t heat/gpu_admin.yaml gpu_admin
    $ openstack stack resource list gpu_admin
    +-------------------+-------------------------------------------------------------------------------------+------------------------------+-----------------+----------------------+
    | resource_name     | physical_resource_id                                                                | resource_type                | resource_status | updated_time         |
    +-------------------+-------------------------------------------------------------------------------------+------------------------------+-----------------+----------------------+
    | openstack_user    | 0956494e188a4d5db024ad7b494b7897                                                    | OS::Keystone::User           | CREATE_COMPLETE | 2018-08-18T03:25:49Z |
    | instance_flavor1  | 04afb7f1-0280-48cf-985a-f4f8d5ac1361                                                | OS::Nova::Flavor             | CREATE_COMPLETE | 2018-08-18T03:25:49Z |
    | internal_net      | a4fc3e39-096a-49c3-8ce2-fec1bfa54b4f                                                | OS::Neutron::Net             | CREATE_COMPLETE | 2018-08-18T03:25:49Z |
    | public_network    | 7cd66979-55bf-4d0f-9113-2589a9b7a498                                                | OS::Neutron::ProviderNet     | CREATE_COMPLETE | 2018-08-18T03:25:49Z |
    | router_interface  | 6f176f5b-9a98-4dc8-bdcf-17989bcea9f2:subnet_id=48d15707-6d21-4cbb-b273-154853c20066 | OS::Neutron::RouterInterface | CREATE_COMPLETE | 2018-08-18T03:25:49Z |
    | openstack_project | c41d9f57927d47df84f54ad1afea9f60                                                    | OS::Keystone::Project        | CREATE_COMPLETE | 2018-08-18T03:25:49Z |
    | internal_router   | 6f176f5b-9a98-4dc8-bdcf-17989bcea9f2                                                | OS::Neutron::Router          | CREATE_COMPLETE | 2018-08-18T03:25:49Z |
    | public_subnet     | 5f3f8b98-3438-4d58-a0da-754d02c09663                                                | OS::Neutron::Subnet          | CREATE_COMPLETE | 2018-08-18T03:25:49Z |
    | internal_subnet   | 48d15707-6d21-4cbb-b273-154853c20066                                                | OS::Neutron::Subnet          | CREATE_COMPLETE | 2018-08-18T03:25:49Z |
    +-------------------+-------------------------------------------------------------------------------------+------------------------------+-----------------+----------------------+
```

Run the Heat stack gpu_user as the tenant user to luanch the instance and associate a floating IP address.

```
    $ sed -e 's/OS_USERNAME=admin/OS_USERNAME=user1/' -e 's/OS_PROJECT_NAME=admin/OS_PROJECT_NAME=tenant1/' -e 's/OS_PASSWORD=.*/OS_PASSWORD=redhat/' overcloudrc > ~/user1.rc
    $ source ~/user1.rc
    $ openstack stack create -t heat/gpu_user.yaml gpu_user
    $ openstack stack resource list gpu_user
    +---------------------+--------------------------------------+----------------------------+-----------------+----------------------+
    | resource_name       | physical_resource_id                 | resource_type              | resource_status | updated_time         |
    +---------------------+--------------------------------------+----------------------------+-----------------+----------------------+
    | server_init         | 7a5236a4-cfdf-46d6-9dcf-06759840297e | OS::Heat::MultipartMime    | CREATE_COMPLETE | 2018-08-17T23:59:13Z |
    | server1_port        | 8849b9c2-3243-43d2-b885-4926637eb7ba | OS::Neutron::Port          | CREATE_COMPLETE | 2018-08-17T23:59:13Z |
    | cuda_init           | ff715321-515e-4666-aac4-76e8ade9182c | OS::Heat::SoftwareConfig   | CREATE_COMPLETE | 2018-08-17T23:59:13Z |
    | server1             | 74784fc1-a5f3-4dd6-b388-74d23fa13ce4 | OS::Nova::Server           | CREATE_COMPLETE | 2018-08-17T23:59:13Z |
    | tenant_key_pair     | generated key pair                   | OS::Nova::KeyPair          | CREATE_COMPLETE | 2018-08-17T23:59:13Z |
    | security_group      | d4156907-e035-480f-94d1-0280e08db33d | OS::Neutron::SecurityGroup | CREATE_COMPLETE | 2018-08-17T23:59:13Z |
    | server1_floating_ip | f3ec1e2a-9534-4a54-a82f-a494bea60fee | OS::Neutron::FloatingIP    | CREATE_COMPLETE | 2018-08-17T23:59:13Z |
    +---------------------+--------------------------------------+----------------------------+-----------------+----------------------+
```

The Keystone key pair is automatically generated. Export the Heat output to a file.

```
    $ openstack stack output show -f value gpu_user private_key | tail -n +3 > gpukey.pem

    $ chmod 600 gpukey.pem
    $ cat gpukey.pem
    -----BEGIN RSA PRIVATE KEY-----
    MIIEowIBAAKCAQEAtrF2+mO7lOsFSJmF0rXGZZ5jpZFMvwc7GdZ9YNJ140jDD/Y7
    LXixwpFdxwRZwt1eHTzPcGuE7SjA9kyisk6D5lPYs1wQbJnnTpk5oOkkdlpwZwdY
    ...
    HajSgbDyjkHVxLFLzQ/HG9w0c6Ab3ewJDH+VHGHVXfMOzDP+8aFN1AGRXechXBlH
    omV/xFg9EW/1W6pkqDPaZQ9I9QAGRpzi6JYtFfPOU/FIkVRkEmof
    -----END RSA PRIVATE KEY-----
```

## Configure Cuda drivers and utilities

The Cuda drivers and utilities are installed by the following OS::Heat::SoftwareConfig resource:

```
    $ grep -A 18 cuda_init: heat/gpu_user.yaml
      cuda_init:
        type: OS::Heat::SoftwareConfig
        properties:
          config: |
            #!/bin/bash
            echo "installing repos" > /tmp/cuda_init.log
            rpm -ivh https://dl.fedoraproject.org/pub/epel/epel-release-latest-7.noarch.rpm
            rpm -ivh https://developer.download.nvidia.com/compute/cuda/repos/rhel7/x86_64/cuda-repo-rhel7-8.0.61-1.x86_64.rpm
            echo "installing cuda and samples" >> /tmp/cuda_init.log
            yum install -y cuda && /usr/local/cuda-9.2/bin/cuda-install-samples-9.2.sh /home/cloud-user
            echo "building cuda samples" >> /tmp/cuda_init.log
            make -j $(grep -c Skylake /proc/cpuinfo) -C /home/cloud-user/NVIDIA_CUDA-9.2_Samples -Wno-deprecated-gpu-targets
            shutdown -r now

      server_init:
        type: OS::Heat::MultipartMime
        properties:
          parts:
          - config: { get_resource: cuda_init }
```

> **NOTE**: Cuda is a proprietary driver that requires DKMS to build the kernel modules. DKMS is available from EPEL. Neither the Cuda drivers nor DKMS are supported by Red Hat.

Verify the drivers are installed correctly:

```
    $ openstack server list
    +--------------------------------------+------+--------+-------------------------------------------+--------------+------------+
    | ID                                   | Name | Status | Networks                                  | Image        | Flavor     |
    +--------------------------------------+------+--------+-------------------------------------------+--------------+------------+
    | 5cc270cc-af03-4f34-ae1a-835a2d246bbc | vm1  | ACTIVE | internal_net=192.168.0.5, 192.168.122.104 | rhel75u1-gpu | m1.xmedium |
    +--------------------------------------+------+--------+-------------------------------------------+--------------+------------+

    $ ssh -l cloud-user -i gpukey.pem 192.168.122.104 sudo lspci | grep -i nvidia
    00:06.0 VGA compatible controller: NVIDIA Corporation GM204GL [Tesla M60] (rev a1)
    00:07.0 VGA compatible controller: NVIDIA Corporation GM204GL [Tesla M60] (rev a1)


    $ ssh -l cloud-user -i gpukey.pem 192.168.122.104 sudo lsmod | grep -i nvidia
    nvidia_drm             39689  0
    nvidia_modeset       1086183  1 nvidia_drm
    nvidia              14037782  1 nvidia_modeset
    drm_kms_helper        177166  2 cirrus,nvidia_drm
    drm                   397988  5 ttm,drm_kms_helper,cirrus,nvidia_drm
    i2c_core               63151  4 drm,i2c_piix4,drm_kms_helper,nvidia
    ipmi_msghandler        46607  2 ipmi_devintf,nvidia
```

## Run sample codes

Verify PCI passthrough and Cuda and properly configured by running sample benchmarks included with the distribution:

```
    $ ssh -l cloud-user -i gpukey.pem 192.168.122.104
    Last login: Sat Aug 18 14:23:58 2018 from undercloud.redhat.local

    $  cat /proc/driver/nvidia/version
    NVRM version: NVIDIA UNIX x86_64 Kernel Module  396.44  Wed Jul 11 16:51:49 PDT 2018
    GCC version:  gcc version 4.8.5 20150623 (Red Hat 4.8.5-28) (GCC) 
```

Run the sample codes installed in the cloud-user home directory. In this example we run a simple Stream test of memory bandwidth and a floating point matrix multiply.

```
    $ ls ~/NVIDIA_CUDA-9.2_Samples/
    0_Simple  1_Utilities  2_Graphics  3_Imaging  4_Finance  5_Simulations  6_Advanced  7_CUDALibraries  bin  common  EULA.txt  Makefile

    $ ~/NVIDIA_CUDA-9.2_Samples/0_Simple/simpleStreams/simpleStreams
    [ simpleStreams ]
    Device synchronization method set to = 0 (Automatic Blocking)
    Setting reps to 100 to demonstrate steady state
    > GPU Device 0: "Tesla M60" with compute capability 5.2
    Device: <Tesla M60> canMapHostMemory: Yes
    > CUDA Capable: SM 5.2 hardware
    > 16 Multiprocessor(s) x 128 (Cores/Multiprocessor) = 2048 (Cores)
    > scale_factor = 1.0000
    > array_size   = 16777216
    > Using CPU/GPU Device Synchronization method (cudaDeviceScheduleAuto)
    > mmap() allocating 64.00 Mbytes (generic page-aligned system memory)
    > cudaHostRegister() registering 64.00 Mbytes of generic allocated system memory
    Starting Test
    memcopy:        8.83
    kernel:         5.77
    non-streamed:   11.08
    4 streams:      5.41
    -------------------------------
    
    $ ~/NVIDIA_CUDA-9.2_Samples/0_Simple/matrixMul/matrixMul
    [Matrix Multiply Using CUDA] - Starting...
    GPU Device 0: "Tesla M60" with compute capability 5.2
    MatrixA(320,320), MatrixB(640,320)
    Computing result using CUDA Kernel...
    done
    Performance= 309.81 GFlop/s, Time= 0.423 msec, Size= 131072000 Ops, WorkgroupSize= 1024 threads/block
    Checking computed result for correctness: Result = PASS
    NOTE: The CUDA Samples are not meant for performancemeasurements. Results may vary when GPU Boost is enabled.
```

Manual instructions for installing Cuda drivers and utilities are found in the Nvidia Cuda Linux installation guide.

## Resources

1. [GPU support in Red Hat OpenStack Platform](https://access.redhat.com/solutions/3080471)
2. [Bugzilla RFE for documentation on confiuring GPUs via PCI passthrough in OpenStack Platform](https://bugzilla.redhat.com/show_bug.cgi?id=1430337)
3. [OpenStack Nova Configure PCI Passthrough](https://docs.openstack.org/nova/queens/admin/pci-passthrough.html)
4. [KVM virtual machine GPU configuration](https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/7/html/virtualization_deployment_and_administration_guide/chap-guest_virtual_machine_device_configuration#sect-device-GPU)
5. [Nvidia Cuda Linux installation guide](https://docs.nvidia.com/cuda/cuda-installation-guide-linux/index.html#runfile-installation)
6. [DKMS support in Red Hat Enterprise Linux](https://access.redhat.com/solutions/1132653)
