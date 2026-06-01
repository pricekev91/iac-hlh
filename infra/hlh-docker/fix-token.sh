#!/bin/bash
pveum user token add root@pve tofu-hlh-docker -privs "LXC.Allocate;VM.Allocate;VM.Config.Disk;VM.Config.Network;VM.PowerMgmt;Datastore.Allocate;Datastore.AllocateSpace"
