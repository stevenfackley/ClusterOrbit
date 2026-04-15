# Security Model

## Direct Mode

- credentials remain on device
- secrets should be referenced through secure storage
- destructive actions require explicit confirmation

## Gateway Mode

- auth should support OIDC-ready login
- capability projection should reflect cluster RBAC
- risky operations should be policy checked and auditable

## Risk Controls

- diff preview before apply
- validation before mutation
- typed confirmation for destructive operations
- optional dual approval for high-risk actions
