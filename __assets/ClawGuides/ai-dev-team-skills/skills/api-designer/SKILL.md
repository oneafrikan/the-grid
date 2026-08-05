# API Designer Skill

You design RESTful APIs with OpenAPI specifications.

## Invocation

```
/api_designer {resource or feature}
```

## Process

### 1. Identify Resources

Map the domain to REST resources:
- What entities exist?
- What are the relationships?
- What operations are needed?

### 2. Design Endpoints

Follow REST conventions:

| Operation | Method | Endpoint | Description |
|-----------|--------|----------|-------------|
| List | GET | `/users` | Get all users |
| Create | POST | `/users` | Create user |
| Read | GET | `/users/{id}` | Get one user |
| Update | PUT | `/users/{id}` | Replace user |
| Patch | PATCH | `/users/{id}` | Partial update |
| Delete | DELETE | `/users/{id}` | Delete user |

### 3. Generate OpenAPI Spec

```yaml
openapi: 3.0.3
info:
  title: {API Name}
  version: 1.0.0
  description: |
    {Description of the API}

servers:
  - url: https://api.example.com/v1
    description: Production
  - url: https://staging-api.example.com/v1
    description: Staging

paths:
  /users:
    get:
      summary: List users
      operationId: listUsers
      tags: [Users]
      parameters:
        - name: limit
          in: query
          schema:
            type: integer
            default: 20
            maximum: 100
        - name: offset
          in: query
          schema:
            type: integer
            default: 0
      responses:
        '200':
          description: List of users
          content:
            application/json:
              schema:
                type: object
                properties:
                  data:
                    type: array
                    items:
                      $ref: '#/components/schemas/User'
                  pagination:
                    $ref: '#/components/schemas/Pagination'
    
    post:
      summary: Create user
      operationId: createUser
      tags: [Users]
      requestBody:
        required: true
        content:
          application/json:
            schema:
              $ref: '#/components/schemas/CreateUserRequest'
      responses:
        '201':
          description: User created
          content:
            application/json:
              schema:
                $ref: '#/components/schemas/User'
        '400':
          $ref: '#/components/responses/BadRequest'

  /users/{id}:
    parameters:
      - name: id
        in: path
        required: true
        schema:
          type: string
    
    get:
      summary: Get user
      operationId: getUser
      tags: [Users]
      responses:
        '200':
          description: User details
          content:
            application/json:
              schema:
                $ref: '#/components/schemas/User'
        '404':
          $ref: '#/components/responses/NotFound'

components:
  schemas:
    User:
      type: object
      required: [id, email, name, createdAt]
      properties:
        id:
          type: string
          format: cuid
          example: "clx1234567890"
        email:
          type: string
          format: email
          example: "user@example.com"
        name:
          type: string
          example: "John Doe"
        createdAt:
          type: string
          format: date-time
        updatedAt:
          type: string
          format: date-time

    CreateUserRequest:
      type: object
      required: [email, name]
      properties:
        email:
          type: string
          format: email
        name:
          type: string
          minLength: 1
          maxLength: 100

    Pagination:
      type: object
      properties:
        total:
          type: integer
        limit:
          type: integer
        offset:
          type: integer
        hasMore:
          type: boolean

    Error:
      type: object
      required: [error, code]
      properties:
        error:
          type: string
          description: Human-readable message
        code:
          type: string
          description: Machine-readable code
        details:
          type: object
          description: Additional context

  responses:
    BadRequest:
      description: Invalid request
      content:
        application/json:
          schema:
            $ref: '#/components/schemas/Error'
          example:
            error: "Validation failed"
            code: "VALIDATION_ERROR"
            details:
              email: "Invalid email format"

    NotFound:
      description: Resource not found
      content:
        application/json:
          schema:
            $ref: '#/components/schemas/Error'
          example:
            error: "User not found"
            code: "NOT_FOUND"

    Unauthorized:
      description: Authentication required
      content:
        application/json:
          schema:
            $ref: '#/components/schemas/Error'
          example:
            error: "Authentication required"
            code: "UNAUTHORIZED"

  securitySchemes:
    bearerAuth:
      type: http
      scheme: bearer
      bearerFormat: JWT

security:
  - bearerAuth: []
```

## Design Principles

### URL Design
- Use nouns, not verbs: `/users` not `/getUsers`
- Use plural: `/users` not `/user`
- Nest for relationships: `/users/{id}/orders`
- Keep flat when possible: `/orders?userId={id}`

### HTTP Status Codes
- `200` OK
- `201` Created
- `204` No Content (for DELETE)
- `400` Bad Request (validation error)
- `401` Unauthorized (no auth)
- `403` Forbidden (no permission)
- `404` Not Found
- `409` Conflict (duplicate)
- `500` Internal Server Error

### Pagination
Always paginate list endpoints:
```json
{
  "data": [...],
  "pagination": {
    "total": 100,
    "limit": 20,
    "offset": 0,
    "hasMore": true
  }
}
```

### Filtering & Sorting
```
GET /users?status=active&sort=-createdAt&limit=10
```

### Versioning
- URL versioning: `/v1/users`
- Header versioning: `Accept: application/vnd.api+json; version=1`

## Output

Save spec to: `output/{project}/architecture/api-spec.yaml`
