output "ebs_volume_ids" {
  description = "IDs of the unattached EBS volumes"
  value = [
    aws_ebs_volume.gp3.id,
    aws_ebs_volume.st1.id,
    aws_ebs_volume.io2.id,
  ]
}

output "eip_allocation_ids" {
  description = "Allocation IDs of the unassociated Elastic IPs"
  value = [
    aws_eip.one.allocation_id,
    aws_eip.two.allocation_id,
  ]
}

output "idle_instance_id" {
  description = "Instance ID of the idle m5.xlarge"
  value       = aws_instance.idle.id
}
