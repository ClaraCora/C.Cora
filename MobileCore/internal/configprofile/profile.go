package configprofile

import (
	"bytes"
	"fmt"
	"go.yaml.in/yaml/v3"
)

// Generate changes only process lookup and rule-provider update intervals.
// The source remains untouched, and proxy-provider health checks are preserved.
func Generate(source []byte, keepAutomatic []string) ([]byte, error) {
	var document yaml.Node
	if err := yaml.Unmarshal(source, &document); err != nil {
		return nil, err
	}
	if len(document.Content) != 1 || document.Content[0].Kind != yaml.MappingNode {
		return nil, fmt.Errorf("configuration must be a YAML mapping")
	}
	root := document.Content[0]
	keep := make(map[string]bool)
	for _, name := range keepAutomatic {
		keep[name] = true
	}
	set(root, "find-process-mode", "off", "!!str")
	providers := get(root, "rule-providers")
	if providers != nil {
		if providers.Kind != yaml.MappingNode {
			return nil, fmt.Errorf("rule-providers must be a mapping")
		}
		for i := 0; i < len(providers.Content); i += 2 {
			name, provider := providers.Content[i].Value, providers.Content[i+1]
			if provider.Kind != yaml.MappingNode {
				return nil, fmt.Errorf("provider %s uses an unsupported alias or value", name)
			}
			if !keep[name] {
				set(provider, "interval", "0", "!!int")
			}
		}
		for name := range keep {
			if get(providers, name) == nil {
				return nil, fmt.Errorf("unknown rule provider: %s", name)
			}
		}
	} else if len(keep) != 0 {
		return nil, fmt.Errorf("no rule providers in this configuration")
	}
	var out bytes.Buffer
	encoder := yaml.NewEncoder(&out)
	encoder.SetIndent(2)
	if err := encoder.Encode(&document); err != nil {
		return nil, err
	}
	if err := encoder.Close(); err != nil {
		return nil, err
	}
	return out.Bytes(), nil
}
func get(node *yaml.Node, key string) *yaml.Node {
	for i := 0; i < len(node.Content); i += 2 {
		if node.Content[i].Value == key {
			return node.Content[i+1]
		}
	}
	return nil
}
func set(node *yaml.Node, key, value, tag string) {
	if current := get(node, key); current != nil {
		current.Kind = yaml.ScalarNode
		current.Tag = tag
		current.Value = value
		current.Content = nil
		current.Alias = nil
		return
	}
	node.Content = append(node.Content, &yaml.Node{Kind: yaml.ScalarNode, Tag: "!!str", Value: key},
		&yaml.Node{Kind: yaml.ScalarNode, Tag: tag, Value: value})
}
