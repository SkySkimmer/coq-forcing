# Call-by-name Forcing in Coq

## Description

This is a plugin for Coq v8.5 that implements the call-by-name forcing translation.
The translation is described in this [draft](https://www.xn--pdrot-bsa.fr/articles/draft-forcing.pdf).

## Install

You need Coq v8.5 development files. The ```COQBIN``` environment variable
should be pointing to the Coq binaries folder. Echoing ```make``` should be
enough then.

## Use

The main features added by the plugin are the two following commands.

### Forcing Translation

```
Forcing Translate foo using Obj Hom.
```

This translates the term ```foo``` in the forcing layer described by the ```Obj``` and ```Hom``` argument. ```Obj``` must have type ```Type``` and ```Hom``` must have type ```Obj -> Obj -> Type```. The translation takes care of the Yoneda embedding so nothing more is expected. The translation currently works for global constants and inductive types.

All constants the term ```foo``` depends on must have been translated prior to the invocation of this command, otherwise it will fail.

```
Forcing Translate foo as id1 ... idn using Obj Hom.
```

Same as the above but allow to give a name to the translated constants. Without the provided name, the automatically generated constant is named ```fooᶠ```.
Note that the translation may generate several new constants, for instance in the inductive cases where in addition to the type, constructors are generated.

### Forcing Implementation


```
Forcing Definition foo : type using Obj Hom.
```

This command  starts the proof mode and let the user provide a term whose type is the forcing translation of ```type```. When the proof is finished, an axiom ```foo``` is added to the environment and the term provided by the user is added as the forcing translation of ```foo```.

```
Forcing Definition foo : type as id using Obj Hom.
```

Same as above but allows to give a name to the translated constant instead of the automatic ```fooᶠ```.

