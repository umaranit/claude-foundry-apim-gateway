# Adds the Foundry deployment names of each allowed model to the team's allowedModels.
# The gateway compares the "model" value of each request with this list, and clients send
# the deployment name (for example claude-sonnet-5-apim), not only the model name.
# Input: the teamGovernance.teams array.
# Required argument: --slurpfile deps <file with the output of az cognitiveservices account deployment list -o json>
def supported: ["claude-sonnet-5", "claude-haiku-4-5", "claude-opus-5"];
(($deps[0] // []) | if type == "array" then . else [] end) as $d
| map(
    (.allowedModels // supported) as $allowed
    | .allowedModels = (
        ($allowed + [ $d[] | . as $dep
                      | select(any($allowed[]; . == ($dep.properties.model.name // "")))
                      | $dep.name ])
        | unique)
  )
