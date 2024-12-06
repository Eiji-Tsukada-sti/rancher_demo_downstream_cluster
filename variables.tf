variable "region" {
  description = "AWS region to deploy resources"
  default     = "us-east-1"
}

variable "instance_type" {
  description = "EC2 instance type"
  default     = "t3.xlarge"
}

variable "ami" {
  description = "AMI ID of the Ubuntu 24.04 LTS"
  default     = "ami-0866a3c8686eaeeba"
}

variable "server_node_count" {
  default = 3
}

variable "agent_node_count" {
  default = 2
}

variable "key_name" {
  description = "SSH key pair name"
  default     = "rke2-ds-node-key"
}

variable "server_token" {
  default     = "my-shared-secret"
}
