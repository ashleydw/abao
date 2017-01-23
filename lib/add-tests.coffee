async = require 'async'
_ = require 'underscore'
csonschema = require 'csonschema'


parseSchema = (source) ->
  return null unless source?
  if source.contains('$schema')
    JSON.parse source
  else
    try
      csonschema.parse source
    catch
      return null

parseBody = (body) ->
  schema = null
  example = null
  if body.type()[0] of types
    schema = typeToSchema(types[body.type()[0]], types)
    example = types[body.type()[0]].example()?.value()
  else if body.type()[0].replace('[]', '') of types
    type = types[body.type()[0].replace('[]', '')]
    schema = typeToSchemaArray(type, types)
    example = '['+type.example()?.value()+']'
  else if body.schema().length > 0 && !test.response.schema
    schemaTmp = body.schema()[0]
    try
      schema = parseSchema schemas[schemaTmp].type()[0]
    catch
      schema = parseSchema  schemaTmp
  else if body.type()[0].replace('[]', '') == 'object'
    schema = typeToSchema(body)
  return {
    schema: schema,
    example: example
  }

getContentType = (bodyArray) ->
  return null unless bodyArray

  contentTypes = []
  bodyArray.forEach (body) ->
    if body.name().match(/^application\/(.*\+)?json/i)
      contentTypes.push(body.name())

  if contentTypes.length > 0 then contentTypes[0] else null

parsedTypesToSchemas = {}

typeToSchemaArray = (type, types) ->
  jsonObject = {}
  jsonObject['$schema'] = "http://json-schema.org/draft-04/schema#"
  jsonObject.type = 'array'
  jsonObject.items = typeToSchema(type, types)
  jsonObject

typeToSchema = (type, types) ->
  # noCache = !!type.type()[0] in ['string', 'number', 'integer', 'object', 'date', 'boolean', 'file', 'nil']
  # unless noCache or type.name() of parsedTypesToSchemas
  jsonObject = type.toJSON({serializeMetadata: false})
  jsonObject = if type.name() of jsonObject then jsonObject[type.name()] else jsonObject
  jsonObject['$schema'] = "http://json-schema.org/draft-04/schema#"
  jsonObject = typeToSchemaRecursive(jsonObject, types)
  return jsonObject
  #parsedTypesToSchemas[type.name()]

typeToSchemaRecursive = (jsonObject, types) ->
  types = types || {}
  if _.isArray(_.result(jsonObject, 'type'))
    jsonObject.type = jsonObject.type[0]

    if jsonObject.type.indexOf('[]') >= 0
      jsonObject.items = type: jsonObject.type.replace('[]', '')
      jsonObject.type = 'array'

      if jsonObject.items.type of types
        jsonObject.items.properties =
          jsonObject.items.type = typeToSchema(types[jsonObject.items.type], types)
        jsonObject.items.type = 'object'

    if jsonObject.type of types
      nestedSchema = typeToSchema(types[jsonObject.type], types)
      delete nestedSchema['$schema']
      delete nestedSchema.required
      jsonObject = _.extend(jsonObject, nestedSchema)

    # Unions @todo
    if jsonObject.type.indexOf('|') >= 0
      jsonObject.type = jsonObject.type.replace(RegExp(' ', 'g'), '')
      jsonObject.type = jsonObject.type.split('|')

  # @todo: Parse array unions like (string | Person)[]

  #add name if not present
  if jsonObject.name? || jsonObject.name == ''
    jsonObject.name = jsonObject.title

  if jsonObject.displayName? && jsonObject.displayName != ''
    jsonObject.name = jsonObject.displayName
  else if jsonObject.name? && jsonObject.name != ''
    jsonObject.name = jsonObject.name

  # delete jsonObject.name
  # delete jsonObject.title
  # delete jsonObject.displayName
  delete jsonObject.structuredExample
  delete jsonObject.example
  delete jsonObject.examples
  
  if jsonObject.type in ['datetime', 'time-only', 'datetime-only', 'datetime']
    jsonObject.type = 'string'
    jsonObject.format = 'date-time'

  if jsonObject.type == 'object' and jsonObject.properties? and _.isObject(jsonObject.properties)
    # Find all required properties
    filtered = _.filter jsonObject.properties, (obj) ->
      !_.isArray(obj.required) && obj.required == true

    if filtered.length > 0
      jsonObject.required = _.map(filtered, 'name')

    # Parse children properties
    _.forEach jsonObject.properties, (propObject, propKey) ->
      delete propObject.required
      typeToSchemaRecursive(propObject, types)
      return
  else if jsonObject.required == null
    jsonObject.required = false
  jsonObject

types = {}

addTests = (raml, tests, hooks, parent, callback, testFactory, apiBaseUri, annotations) ->

  annotations = annotations || {}
  return callback() unless raml.resources().length > 0

  if raml.expand
    raml = raml.expand(true)

  schemas = {}
  if raml.schemas
    raml.schemas().forEach (type) ->
      schemas[type.name()] = type

  if raml.types
    raml.types().forEach (type) ->
      types[type.name()] = type

  raml.annotations().forEach (anno) ->
    annotations[anno.name()] = anno.toJSON({serializeMetadata: false})

  # Iterate endpoint
  async.each raml.resources(), (resource, callback) ->
    path = resource.relativeUri().value()
    params = {}

    # Apply parent properties
    path = parent.path + path if parent.path
    params = _.clone parent.params if parent.params

    # Setup param
    resource.uriParameters().forEach (up) ->
      if up.example()? || up.examples().length > 0
        params[up.name()] = up.toJSON({serializeMetadata: false})
      else if up.type().length > 0 && up.type()[0] of types
        upType = types[up.type()[0]]
        params[up.name()] = upType.toJSON({serializeMetadata: false})

      unless up.name() of params
        console.warn('Couldnt process uriParameter: ', up.name())

    # In case of issue #8, resource does not define methods
    resource.methods ?= []

    # Iterate response method
    async.each resource.methods(), (api, callback) ->
      query = {}
      method = api.method().toUpperCase()

      resourceAnnotations = _.clone(annotations)
      api.annotations().forEach (anno) ->
        resourceAnnotations[anno.name()] = anno.toJSON({serializeMetadata: false})

      # Setup query
      api.queryParameters().forEach (qp) ->
        return unless qp.required()
        if qp.example()?
          query[qp.name()] = qp.example().value()
        else if qp.examples().length > 0
          query[qp.name()] = qp.examples()[_.random(0, qp.examples().length-1)].value()
        else if qp.type()[0] of types && (types[qp.type()[0]].example()? || types[qp.type()[0]].examples().length > 0)
          type = types[qp.type()[0]]
          if type.example()?
            query[qp.name()] = type.example().value()
          else
            query[qp.name()] = type.examples()[_.random(0, type.examples().length-1)].value()
        else
          console.warn('Couldnt process queryParameters: ', qp.name())

      # Iterate response status
      api.responses().forEach (res) ->

        status = res.code().value()
        testName = "#{method} #{path} -> #{status}"

        # Append new test to tests
        test = testFactory.create(testName, hooks.contentTests[testName])
        tests.push test

        test.annotations = resourceAnnotations

        # Update test.request
        test.request.path = apiBaseUri + path
        test.request.method = method

        headers = {}
        api.headers().forEach (header) ->

          return unless header.required()

          if header.example()?
            headers[header.name()] = header.example().value()
          else if header.examples().length > 0
            headers[header.name()] = header.examples()[_.random(0, header.examples().length-1)].value()
          else if header.type()[0] of types && \
                  (types[header.type()[0]].example()? || \
                   types[header.type()[0]].examples().length > 0)
            type = types[header.type()[0]]
            if type.example()?
              headers[header.name()] = type.example().value()
            else
              headers[header.name()] = \
                type.examples()[_.random(0, type.examples().length-1)].value()
          else
            console.warn(testName + ': Couldnt process header: ', \
                         header.name(), header.type(), \
                         typeToSchema(types['Guid']))

        test.request.headers = headers
        contentType = getContentType(api.body())

        # select compatible content-type in request body (to support vendor tree types, i.e. application/vnd.api+json)
        if contentType
          test.request.headers['Content-Type'] = contentType
          try
            api.body().forEach (body) ->
              return unless body.name() == contentType
              bodyType = body.type()[0].replace('[]', '')
              if body.example()?
                test.request.body = JSON.parse body.example().value()
              else if body.examples().length > 0
                test.request.body = JSON.parse body.examples()[_.random(0, body.examples().length - 1)].value()
              else if bodyType of types && (types[bodyType].example()? || types[bodyType].examples().length > 0)
                type = types[bodyType]
                if type.example()?
                  test.request.body = type.example().value()
                else
                  test.request.body = type.examples()[_.random(0, type.examples().length-1)].value()
                if body.type()[0].indexOf('[]') >= 0
                  test.request.body = '['+test.request.body+']'
          catch
            console.warn testName + ": cannot parse JSON example request body"
        test.request.params = params
        test.request.query = query

        # Update test.response
        test.response.status = status
        test.response.schema = null

        if res.body().length > 0
          # expect content-type of response body to be identical to request body
          if contentType
            res.body().forEach (body) ->
              if body.example()? and body.example().value()?
                test.response.example = body.example().value()
              if !test.response.schema && body.name() == contentType
                schema = parseBody(body)
                test.response.schema = schema.schema if schema.schema?
                test.response.example = schema.example if schema.example? and !test.response.example

          # otherwise filter in responses section for compatible content-types
          # (vendor tree, i.e. application/vnd.api+json)
          else
            res.body().forEach (body) ->
              if body.example()? and body.example().value()?
                test.response.example = body.example().value()
              if !test.response.schema && body.name().match(/^application\/(.*\+)?json/i)
                schema = parseBody(body)
                test.response.schema = schema.schema if schema.schema?
                test.response.example = schema.example if schema.example? and !test.response.example

      callback()
    , (err) ->
      if err
        console.error(err)
        return callback(err)

      # Recursive
      addTests resource, tests, hooks, {path, params}, callback, testFactory, apiBaseUri, annotations
  , callback



module.exports = addTests
