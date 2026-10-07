// Generates an optional configuration copy; never runs in the NE.
package main

import (
	"cora/mobilecore/internal/configprofile"
	"flag"
	"fmt"
	"os"
	"strings"
)

func main() {
	input := flag.String("input", "", "source YAML configuration")
	output := flag.String("output", "", "new YAML file (must not already exist)")
	keep := flag.String("keep-auto", "", "comma-separated rule-provider names retaining automatic updates")
	flag.Parse()
	if *input == "" || *output == "" {
		fail(fmt.Errorf("input and output are required"))
	}
	source, err := os.ReadFile(*input)
	if err != nil {
		fail(err)
	}
	var names []string
	for _, name := range strings.Split(*keep, ",") {
		if name = strings.TrimSpace(name); name != "" {
			names = append(names, name)
		}
	}
	profile, err := configprofile.Generate(source, names)
	if err != nil {
		fail(err)
	}
	file, err := os.OpenFile(*output, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if err != nil {
		fail(err)
	}
	_, err = file.Write(profile)
	closeErr := file.Close()
	if err != nil {
		_ = os.Remove(*output)
		fail(err)
	}
	if closeErr != nil {
		_ = os.Remove(*output)
		fail(closeErr)
	}
	fmt.Println("Created optional profile. Process fields may be empty; interval: 0 providers still support manual refresh.")
}
func fail(err error) { fmt.Fprintln(os.Stderr, err); os.Exit(1) }
