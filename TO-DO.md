# Research online how to implement changes in the dock.

MacEnhance made **cDock**, a tweak for macOS modification of the dock look/behavior.

I'd love to implement something like this for **HiddenGem**—which I want to update `lostnfound.m` to use the methods.

- [cDock CoreDock blog post](https://www.macenhance.com/blog/2021/coredock.html) explains how cDock modifications were implemented. Dig into that.  
- It also links to:
  - [Gist: w0lfschild/CoreDock headers](https://gist.github.com/w0lfschild/90db263867f469738c01e9e2d937f874)  
  - [CoreDockPrivate.h](https://github.com/rcarmo/qsb-mac/blob/master/QuickSearchBox/externals/UndocumentedGoodness/CoreDock/CoreDockPrivate.h)  
  - [Gist: ThatsJustCheesy/CoreDock headers](https://gist.github.com/ThatsJustCheesy/823c806d78e6b3628cd6fdc86eb290d4)

They link against `ApplicationServices.framework`, so we must keep that in mind.

**Ammonia injector** will handle loading the `.dylib` injection, so we won't worry about injection—only about hooking dock methods and modifications.

## Let's get started!

1. **Goal**: Hide **Finder** and **Trash** with a toggle.  
2. **Implementation**: `lostnfound.m` needs a rewrite to properly hook the dock and modify whether Finder or Trash dock icons are rendered or not—I want the ability to remove them **permanently**!
