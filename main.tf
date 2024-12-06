provider "aws" {
  region = var.region
}

resource "aws_vpc" "vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    "Name" = "downstream-cluster-vpc"
  }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.vpc.id
}

resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
}

data "aws_availability_zones" "available" {

}

resource "aws_subnet" "control_plane" {
  count                   = 3
  vpc_id                  = aws_vpc.vpc.id
  cidr_block              = cidrsubnet(aws_vpc.vpc.cidr_block, 8, count.index)
  availability_zone       = element(data.aws_availability_zones.available.names, count.index)
  map_public_ip_on_launch = true

  tags = {
    "Name" = "downstream-control-plane-subnet-${count.index + 1}"
  }
}

resource "aws_subnet" "worker_node" {
  count                   = 3
  vpc_id                  = aws_vpc.vpc.id
  cidr_block              = cidrsubnet(aws_vpc.vpc.cidr_block, 8, count.index + length(aws_subnet.control_plane))
  availability_zone       = element(data.aws_availability_zones.available.names, count.index)
  map_public_ip_on_launch = true

  tags = {
    "Name" = "downstream-worker-node-subnet-${count.index + 1}"
  }
}

resource "aws_route_table_association" "control_plane" {
  count          = 3
  subnet_id      = aws_subnet.control_plane[count.index].id
  route_table_id = aws_route_table.public_rt.id
}

resource "aws_route_table_association" "worker_node" {
  count          = 3
  subnet_id      = aws_subnet.worker_node[count.index].id
  route_table_id = aws_route_table.public_rt.id
}

resource "aws_security_group" "instance_sg" {
  vpc_id = aws_vpc.vpc.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 2379
    to_port     = 2380
    protocol    = "tcp"
    self        = true
    description = "etcd client, etcd peer"
  }

  ingress {
    from_port   = 6443
    to_port     = 6443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Kubernetes API"
  }

  ingress {
    from_port   = 8472
    to_port     = 8472
    protocol    = "udp"
    self        = true
    description = "Canal/Flannel VXLAN overlay networking"
  }

  ingress {
    from_port   = 9099
    to_port     = 9099
    protocol    = "tcp"
    self        = true
    description = "Canal/Flannel health check"
  }

  ingress {
    from_port   = 9345
    to_port     = 9345
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "rke2 supervisor API"
  }

  ingress {
    from_port   = 9796
    to_port     = 9796
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Default port required by node-exporters"
  }

  ingress {
    from_port   = 10250
    to_port     = 10252
    protocol    = "tcp"
    self        = true
    description = "kubelet, kube-scheduler, kube-controller"
  }

  ingress {
    from_port   = 10256
    to_port     = 10256
    protocol    = "tcp"
    self        = true
    description = "kube-proxy"
  }

  ingress {
    from_port   = 30000
    to_port     = 32767
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "NodePort port range"
  }

  ingress {
    from_port   = 30000
    to_port     = 32767
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "NodePort port range"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "tls_private_key" "instance" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "aws_key_pair" "instance" {
  key_name   = var.key_name
  public_key = tls_private_key.instance.public_key_openssh
  tags = {
    "Name" = var.key_name
  }
}

# ローカル環境にインスタンス接続用のpemキーを作成
resource "local_file" "private_key_pem" {
  filename        = "rancher_demo_downstream_instance_key.pem"
  content         = tls_private_key.instance.private_key_pem
  file_permission = "0600"
}

resource "aws_instance" "control_plane" {
  count                       = var.server_node_count
  ami                         = var.ami
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.control_plane[count.index].id
  security_groups             = [aws_security_group.instance_sg.id]
  associate_public_ip_address = true
  key_name                    = aws_key_pair.instance.key_name

  root_block_device {
    volume_size = 20
  }

  tags = {
    "Name" = "downstream-control-plane-${count.index + 1}"
  }
}

resource "aws_instance" "worker_node" {
  count                       = var.agent_node_count
  ami                         = var.ami
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.worker_node[count.index].id
  security_groups             = [aws_security_group.instance_sg.id]
  associate_public_ip_address = true
  key_name                    = aws_key_pair.instance.key_name

  depends_on = [aws_instance.control_plane]

  root_block_device {
    volume_size = 20
  }

  tags = {
    "Name" = "downstream-worker-node-${count.index + 1}"
  }
}

resource "aws_lb" "rke2_master_nlb" {
  name                             = "downstream-master-nlb"
  internal                         = false
  load_balancer_type               = "network"
  subnets                          = [for subnet in aws_subnet.control_plane : subnet.id]
  enable_cross_zone_load_balancing = true
}

resource "aws_lb_target_group" "rke2_master_nlb_80_tg" {
  name     = "downstream-nlb-80-tg"
  port     = 80
  protocol = "TCP"
  vpc_id   = aws_vpc.vpc.id
  health_check {
    interval            = 30
    protocol            = "TCP"
    port                = "traffic-port"
    healthy_threshold   = 10
    unhealthy_threshold = 10
  }
}

resource "aws_lb_listener" "rke2_master_nlb_80_listerner" {
  load_balancer_arn = aws_lb.rke2_master_nlb.arn
  port              = 80
  protocol          = "TCP"
  default_action {
    target_group_arn = aws_lb_target_group.rke2_master_nlb_80_tg.arn
    type             = "forward"
  }
}

resource "aws_lb_target_group" "rke2_master_nlb_443_tg" {
  name     = "downstream-nlb-443-tg"
  port     = 443
  protocol = "TCP"
  vpc_id   = aws_vpc.vpc.id
  health_check {
    interval            = 30
    protocol            = "TCP"
    port                = "traffic-port"
    healthy_threshold   = 10
    unhealthy_threshold = 10
  }
}

resource "aws_lb_listener" "rke2_master_nlb_443_listerner" {
  load_balancer_arn = aws_lb.rke2_master_nlb.arn
  port              = 443
  protocol          = "TCP"
  default_action {
    target_group_arn = aws_lb_target_group.rke2_master_nlb_443_tg.arn
    type             = "forward"
  }
}

resource "aws_lb_target_group" "rke2_master_nlb_tg" {
  name     = "downstream-nlb-tg"
  port     = 6443
  protocol = "TCP"
  vpc_id   = aws_vpc.vpc.id
  health_check {
    interval            = 30
    protocol            = "TCP"
    port                = "6443"
    healthy_threshold   = 10
    unhealthy_threshold = 10
  }
}

resource "aws_lb_listener" "rke2_master_nlb_listerner" {
  load_balancer_arn = aws_lb.rke2_master_nlb.arn
  port              = 6443
  protocol          = "TCP"
  default_action {
    target_group_arn = aws_lb_target_group.rke2_master_nlb_tg.arn
    type             = "forward"
  }
}

resource "aws_lb_target_group" "rke2_master_supervisor_nlb_tg" {
  name                 = "downstream-nlb-supervisor-tg"
  port                 = 9345
  protocol             = "TCP"
  vpc_id               = aws_vpc.vpc.id
  deregistration_delay = "300"
  health_check {
    interval            = 30
    protocol            = "TCP"
    port                = "9345"
    healthy_threshold   = 10
    unhealthy_threshold = 10
  }
}

resource "aws_lb_listener" "rke2_master_supervisor_nlb_listener" {
  load_balancer_arn = aws_lb.rke2_master_nlb.arn
  port              = 9345
  protocol          = "TCP"
  default_action {
    target_group_arn = aws_lb_target_group.rke2_master_supervisor_nlb_tg.arn
    type             = "forward"
  }
}

resource "aws_lb_target_group_attachment" "rke2_nlb_80_attachment" {
  count            = length(aws_instance.control_plane)
  target_group_arn = aws_lb_target_group.rke2_master_nlb_80_tg.arn
  target_id        = aws_instance.control_plane[count.index].id
  port             = 80
}

resource "aws_lb_target_group_attachment" "rke2_nlb_443_attachment" {
  count            = length(aws_instance.control_plane)
  target_group_arn = aws_lb_target_group.rke2_master_nlb_443_tg.arn
  target_id        = aws_instance.control_plane[count.index].id
  port             = 443
}

resource "aws_lb_target_group_attachment" "rke2_nlb_attachment" {
  count            = length(aws_instance.control_plane)
  target_group_arn = aws_lb_target_group.rke2_master_nlb_tg.arn
  target_id        = aws_instance.control_plane[count.index].id
  port             = 6443
}

resource "aws_lb_target_group_attachment" "rke2_nlb_supervisor_attachment" {
  count            = length(aws_instance.control_plane)
  target_group_arn = aws_lb_target_group.rke2_master_supervisor_nlb_tg.arn
  target_id        = aws_instance.control_plane[count.index].id
  port             = 9345
}

output "nlb_dns" {
  value = aws_lb.rke2_master_nlb.dns_name
}

output "control_plane_public_ips" {
  value = aws_instance.control_plane[*].public_ip
}

output "worker_node_public_ips" {
  value = aws_instance.worker_node[*].public_ip
}
