#!/bin/bash

exec openstack overcloud deploy \
--templates /usr/share/openstack-tripleo-heat-templates \
--timeout 90 \
--verbose \
-r /home/stack/templates/roles_data.yaml \
-e /home/stack/templates/node-count.yaml \
-e /usr/share/openstack-tripleo-heat-templates/environments/network-isolation.yaml \
-e /usr/share/openstack-tripleo-heat-templates/environments/services-docker/octavia.yaml \
-e /home/stack/templates/environments/10-ntp.yaml \
-e /home/stack/templates/environments/10-network.yaml \
-e /home/stack/templates/environments/20-network-environment.yaml \
-e /home/stack/templates/environments/25-hostname-map.yaml \
-e /home/stack/templates/environments/30-ips-from-pool-all.yaml \
-e /home/stack/templates/environments/50-vip.yaml \
-e /home/stack/templates/environments/55-rsvd_host_memory.yaml \
--log-file /home/stack/overcloud-deploy.log
