export interface ReadKitLocation {
  resourceIndex: number;
  domPos: string;
}

export interface ReadKitBookmarkPayload {
  id: string;
  title: string;
  location: ReadKitLocation;
}
