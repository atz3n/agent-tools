# LLM Wiki Template


Copy + paste the llm-wiki folder and run the following prompt to initialize a custom llm wiki. Replace `__YOUR_WIKI_USE_CASE__` with your specific use case. Make sure to use a powerful model for wiki creation and document adding. Querying can be done with a lighter model.

```
Read wiki.md (Karpathy's idea for a personal wiki) and spec.md (Google's specification for a standardized format) in the current folder, and use them to create only the structure and basic file/folder setup for a __YOUR_WIKI_USE_CASE__ wiki. Do not fill in any content; just set up the framework according to Karpathy's concept and follow the Google specification.
```

- The wiki.md content is copied from Karpathy’s [gist](https://gist.github.com/karpathy/442a6bf555914893e9891c11519de94f)
- The spec.md content is copied from Googles okf [spec](https://github.com/GoogleCloudPlatform/knowledge-catalog/blob/main/okf/SPEC.md)

Add new content to the `raw` folder and tell the LLM to add it into the wiki. I.e.:
```
I've put a new document to the raw folder. Add it to the wiki.
```