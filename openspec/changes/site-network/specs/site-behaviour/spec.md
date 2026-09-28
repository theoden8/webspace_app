## MODIFIED Requirements

### Requirement: BEHAV-002 — Settings row summarises without opening

The Behaviour, Network, Privacy and Permissions rows SHALL sit at the foot of
site settings under the "Site" heading, below the leaf controls, in that
order. Behaviour leads and Network follows (NET-002): they are what the app
does with the site and how it carries its traffic, and the two rows after them
are what the site is allowed to do.

The Behaviour row SHALL summarise its state without being opened: the names of
the switches that are on, at most two followed by a "{count} more" overflow, or
"Nothing enabled" when none is. Always open Home counts as on while incognito
forces it, since that is what the screen shows. The External links choice
counts as on outside its default: "Open external links in browser" in the
browser mode, "Block external links" in the block mode.

#### Scenario: The rows keep their order

**Given** the user opens site settings
**Then** the rows under "Site" read Behaviour, Network, Privacy, Permissions,
top to bottom

#### Scenario: The row names what is on

**Given** a site with Kiosk mode on and nothing else
**Then** the Behaviour row in site settings reads "Kiosk mode"

#### Scenario: The row names a blocking site

**Given** a site with nothing else on and External links set to Block
**Then** the Behaviour row reads "Block external links"

#### Scenario: More than two overflow

**Given** a site with Kiosk mode, Full screen mode and HTML caching on
**Then** the row names two of them and then "1 more"

#### Scenario: Nothing on

**Given** a site with every behaviour switch off and External links set to
Open in the app
**Then** the row reads "Nothing enabled"
