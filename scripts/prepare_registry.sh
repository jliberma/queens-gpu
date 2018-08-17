#!/usr/bin/env bash
# prepare the local registery on the undercloud

sudo sed -i.orig 's/8787"$/8787 --insecure-registry docker-registry.engineering.redhat.com"/' /etc/sysconfig/docker
sudo systemctl restart docker.service

openstack overcloud container image prepare \
  --namespace docker-registry.engineering.redhat.com/rhosp13 \
  --output-images-file ~/templates/container-images.yaml \
  --output-env-file ~/templates/docker-registry.yaml \
  --push-destination 172.16.0.1:8787 \
  -e /home/stack/templates/node-count.yaml \
  -e /usr/share/openstack-tripleo-heat-templates/environments/network-isolation.yaml \
  -e /usr/share/openstack-tripleo-heat-templates/environments/services-docker/octavia.yaml \
  -e /home/stack/templates/docker-registry.yaml \
  -e /home/stack/templates/environments/10-network.yaml \
  -e /home/stack/templates/environments/10-ntp.yaml \
  -e /home/stack/templates/environments/20-network-environment.yaml \
  -e /home/stack/templates/environments/25-hostname-map.yaml \
  -e /home/stack/templates/environments/30-ips-from-pool-all.yaml \
  -e /home/stack/templates/environments/50-vip.yaml \
  -e /home/stack/templates/environments/55-rsvd_host_memory.yaml

openstack overcloud container image upload \
  --verbose --config-file ~/templates/container-images.yaml

curl http://172.16.0.1:8787/v2/_catalog | jq .

