local BasePlugin = require "kong.plugins.base_plugin"
local OidcHandler = BasePlugin:extend()
local utils = require("kong.plugins.oidc.utils")
local filter = require("kong.plugins.oidc.filter")
local session = require("kong.plugins.oidc.session")

OidcHandler.PRIORITY = 1000


function OidcHandler:new()
  OidcHandler.super.new(self, "oidc")
end

function OidcHandler:access(config)
  OidcHandler.super.access(self)
  local oidcConfig = utils.get_options(config, ngx)

  if filter.shouldProcessRequest(oidcConfig) then
    session.configure(config)
    handle(oidcConfig)
  else
    ngx.log(ngx.DEBUG, "OidcHandler ignoring request, path: " .. ngx.var.request_uri)
  end

  ngx.log(ngx.DEBUG, "OidcHandler done")
end

function handle(oidcConfig)
  local response
  if oidcConfig.introspection_endpoint then
    response = introspect(oidcConfig)
    if response then
      if oidcConfig.roles then
        authorize(oidcConfig.roles, response.realm_access.roles, response.username)
      end
      utils.injectUser(response, oidcConfig.userinfo_header_name)
      utils.injectGroups(response, oidcConfig.groups_claim)
    end
  end

  if response == nil then
    response = make_oidc(oidcConfig)
    if response then
      if (not oidcConfig.disable_userinfo_header
          and response.user) then
        utils.injectUser(response.user, oidcConfig.userinfo_header_name)
        utils.injectGroups(response.user, oidcConfig.groups_claim)
      end
      if (not oidcConfig.disable_access_token_header
          and response.access_token) then
        utils.injectAccessToken(response.access_token, oidcConfig.access_token_header_name, oidcConfig.access_token_as_bearer)
      end
      if (not oidcConfig.disable_id_token_header
          and response.id_token) then
        utils.injectIDToken(response.id_token, oidcConfig.id_token_header_name)
      end
    end
  end
end

function make_oidc(oidcConfig)
  ngx.log(ngx.DEBUG, "OidcHandler calling authenticate, requested path: " .. ngx.var.request_uri)
  local unauth_action = oidcConfig.unauth_action
  if unauth_action ~= "auth" then
    -- constant for resty.oidc library
    unauth_action = "deny"
  end
  local res, err = require("resty.openidc").authenticate(oidcConfig, ngx.var.request_uri, unauth_action)

  if err then
    if err == 'unauthorized request' then
      utils.exit(ngx.HTTP_UNAUTHORIZED, err, ngx.HTTP_UNAUTHORIZED)
    else
      if oidcConfig.recovery_page_path then
    	  ngx.log(ngx.DEBUG, "Redirecting to recovery page: " .. oidcConfig.recovery_page_path)
        ngx.redirect(oidcConfig.recovery_page_path)
      end
      utils.exit(ngx.HTTP_INTERNAL_SERVER_ERROR, err, ngx.HTTP_INTERNAL_SERVER_ERROR)
    end
  end
  return res
end

function introspect(oidcConfig)
  if utils.has_bearer_access_token() or oidcConfig.bearer_only == "yes" then
    local res, err = require("resty.openidc").introspect(oidcConfig)
    if err then
      if oidcConfig.bearer_only == "yes" then
        ngx.header["WWW-Authenticate"] = 'Bearer realm="' .. oidcConfig.realm .. '",error="' .. err .. '"'
        utils.exit(ngx.HTTP_UNAUTHORIZED, err, ngx.HTTP_UNAUTHORIZED)
      end
      return nil
    end
    ngx.log(ngx.DEBUG, "OidcHandler introspect succeeded, requested path: " .. ngx.var.request_uri)
    return res
  end
  return nil
end

function authorize(roles, userRoles, username)
  ngx.log(ngx.DEBUG, "Comparing API roles with user scopes. Roles:" .. roles)

  if utils.hasRequiredRoles(roles, userRoles) == false then
    ngx.log(ngx.INFO, "User " .. username .. " is not authorized")
    utils.exit(ngx.HTTP_FORBIDDEN, "Forbidden", ngx.HTTP_FORBIDDEN)
  end
end

return OidcHandler
