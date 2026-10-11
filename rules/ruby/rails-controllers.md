---
paths:
  - "**/app/controllers/**/*.rb"
---
# Rails controllers

- List attributes explicitly in `params.require(...).permit(...)`; `permit!` permits the whole hash without checking the values, including attributes added to the model later.
- Redirect to a user-supplied URL through `url_from(params[:redirect_url]) || root_url`; `allow_other_host: true` with a user-provided param is an open redirect.
- Check that the requested file is inside the expected directory before `send_file`; `send_file(params[:path])` lets a user download any file on the server.
