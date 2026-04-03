Class {
	#name : 'BaselineOfPharoMCPServer',
	#superclass : 'BaselineOf',
	#category : 'BaselineOfPharoMCPServer',
	#package : 'BaselineOfPharoMCPServer'
}

{ #category : 'baselines' }
BaselineOfPharoMCPServer >> baseline: spec [
	<baseline>

	spec for: #pharo do: [
		spec baseline: 'NeoJSON' with: [
			spec repository: 'github://svenvc/NeoJSON/repository' ].

		spec
			package: 'PharoMCPServer' with: [ spec requires: #('NeoJSON') ];
			group: 'default' with: #('PharoMCPServer') ]
]
