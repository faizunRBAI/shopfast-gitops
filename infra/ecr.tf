# ---------------------------------------------------------------------------
# Amazon ECR for the ShopFast image.
#
# image_tag_mutability = IMMUTABLE enforces the "immutable tags" requirement at
# the registry level: a given Git SHA tag can never be overwritten, so what was
# tested is exactly what runs.
# ---------------------------------------------------------------------------

resource "aws_ecr_repository" "shopfast" {
  name                 = "${var.project_name}-shopfast"
  image_tag_mutability = "IMMUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }
}

resource "aws_ecr_lifecycle_policy" "shopfast" {
  repository = aws_ecr_repository.shopfast.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep the 30 most recent images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 30
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}
