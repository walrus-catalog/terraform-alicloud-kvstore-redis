locals {
  project_name     = coalesce(try(var.context["project"]["name"], null), "default")
  project_id       = coalesce(try(var.context["project"]["id"], null), "default_id")
  environment_name = coalesce(try(var.context["environment"]["name"], null), "test")
  environment_id   = coalesce(try(var.context["environment"]["id"], null), "test_id")
  resource_name    = coalesce(try(var.context["resource"]["name"], null), "example")
  resource_id      = coalesce(try(var.context["resource"]["id"], null), "example_id")

  namespace = join("-", [local.project_name, local.environment_name])
  tags = {
    "walrus.seal.io/project-id"       = local.project_id
    "walrus.seal.io/environment-id"   = local.environment_id
    "walrus.seal.io/resource-id"      = local.resource_id
    "walrus.seal.io/project-name"     = local.project_name
    "walrus.seal.io/environment-name" = local.environment_name
    "walrus.seal.io/resource-name"    = local.resource_name
  }
}

#
# Ensure
#

data "alicloud_vpcs" "selected" {
  ids = [var.infrastructure.vpc_id]

  lifecycle {
    postcondition {
      condition     = length(self.ids) == 1
      error_message = "Failed to get available VPC"
    }
  }
}

data "alicloud_vswitches" "selected" {
  vpc_id = var.infrastructure.vpc_id

  lifecycle {
    postcondition {
      condition     = var.architecture == "Replication" ? length(self.ids) > 1 : length(self.ids) > 0
      error_message = "Failed to get available VSwitch"
    }
  }
}

data "alicloud_zones" "selected" {
  available_resource_creation = "KVStore"
}

#
# Random
#

# create a random password for blank password input.

resource "random_password" "password" {
  length      = 16
  special     = false
  lower       = true
  min_lower   = 3
  min_upper   = 3
  min_numeric = 3
}

# create the name with a random suffix.

resource "random_string" "name_suffix" {
  length  = 10
  special = false
  upper   = false
}


locals {
  name     = join("-", [local.resource_name, random_string.name_suffix.result])
  fullname = join("-", [local.namespace, local.name])
  password = coalesce(var.password, random_password.password.result)
}

#
# Deployment
#

locals {
  version = coalesce(var.engine_version, "5.0")
}

# create security group.

resource "alicloud_security_group" "target" {
  name   = local.fullname
  vpc_id = var.infrastructure.vpc_id

  tags = local.tags
}

resource "alicloud_security_group_rule" "target" {
  security_group_id = alicloud_security_group.target.id

  type        = "ingress"
  ip_protocol = "tcp"
  cidr_ip     = data.alicloud_vpcs.selected.vpcs[0].cidr_block
  port_range  = "6379/6379"
  description = "Access Redis from VPC"
}

locals {
  node_type_map = {
    1 = "readone"
    3 = "readthree"
    5 = "readfive"
  }
}

data "alicloud_kvstore_instance_classes" "selected" {
  engine               = "Redis"
  engine_version       = local.version
  zone_id              = data.alicloud_zones.selected.zones[0].id
  architecture         = var.architecture == "replication" ? "rwsplit" : "standard"
  node_type            = var.architecture == "replication" ? local.node_type_map[var.replication_readonly_replicas] : null
  instance_charge_type = "PostPaid"
}

resource "alicloud_kvstore_instance" "default" {
  db_instance_name = local.fullname
  instance_type    = "Redis"
  engine_version   = local.version
  tags             = local.tags

  vswitch_id        = data.alicloud_vswitches.selected.ids[0]
  security_group_id = alicloud_security_group.target.id
  security_ips      = [data.alicloud_vpcs.selected.vpcs[0].cidr_block]

  password = local.password
  port     = 6379

  instance_class = data.alicloud_kvstore_instance_classes.selected.instance_classes[0]
}